-- __Battleship__/control.lua
-- Factorio 2.0

-- Debug helper
-- Controlled by mod settings:
-- - runtime-global: battleship-debug
-- - runtime-global: battleship-debug-global
-- If settings are missing, debug defaults to false.

local function _setting_exists_global(name)
  local ok, s = pcall(function() return settings.global[name] end)
  return ok and s ~= nil
end

local function debug_enabled(player)
  if not (game and settings) then return false end

  -- Global (per map)
  if _setting_exists_global("battleship-debug-global") then
    if settings.global["battleship-debug-global"].value == true then
      return true
    end
  end

  -- Global (map-wide)
  if _setting_exists_global("battleship-debug") then
    if settings.global["battleship-debug"].value == true then
      return true
    end
  end

  return false
end

local function dbg(msg, player_index)
  local player = nil
  if player_index and game and game.players then
    player = game.players[player_index]
  end
  if not debug_enabled(player) then return end
  log(msg)
  if game and game.print then game.print(msg) end
end

local BATTLESHIP_NTH_TICK = 5
local VISUAL_SYNC_NTH_TICK = 1
local BATTLESHIP_NAME = "battleship"
local INDEP_BATTLESHIP_NAME = "indep-battleship"
local AIRCRAFT_CARRIER_NAME = "aircraft-carrier"
local INDEP_AIRCRAFT_CARRIER_NAME = "indep-aircraft-carrier"
local PATROL_BOAT_NAME = "patrol-boat"
local INDEP_PATROL_BOAT_NAME = "indep-patrol-boat"
local PATROL_TURRET_NAME = "patrol-boat-missile-turret"
local PATROL_PROTECT_TOOL = "patrol-boat-protect-tool"
local ESCORT_CLICK_INPUT = "battleship-escort-click"
local AIRCRAFT_CARRIER_ENGINE_NAME = "cargo_ship_engine"
local AIRCRAFT_CARRIER_ROBOPORT_NAME = "aircraft-carrier-roboport"
local AIRCRAFT_CARRIER_LANDING_PAD_NAME = "aircraft-carrier-landing-pad"
local AIRCRAFT_CARRIER_REQUEST_PROXY_NAME = "aircraft-carrier-request-proxy"
local AIRCRAFT_CARRIER_POWER_INTERFACE_NAME = "aircraft-carrier-power-interface"
local AIRCRAFT_CARRIER_POWER_POLE_NAME = "aircraft-carrier-power-pole"

-- Tunables (defaults). Also exposed as runtime-global settings.
local DEFAULT_PATROL_FOLLOW_MIN_DISTANCE = 10
local DEFAULT_PATROL_FOLLOW_MAX_DISTANCE = 30
local DEFAULT_PATROL_FOLLOW_STEP = 0.6

local DEFAULT_ESCORT_UPDATE_TICKS = 15
local DEFAULT_ESCORT_MIN_SEPARATION_TILES = 9
local DEFAULT_ESCORT_AVOID_STRENGTH = 2.5
local DEFAULT_BATTLESHIP_AMMO_REFILL_TICKS = 60
local DEFAULT_PATROL_AMMO_REFILL_TICKS = 30

local DEFAULT_RADAR_CHART_TICKS = 180
local DEFAULT_RADAR_MIN_MOVE_FOR_RECHART = 4
local DEFAULT_FORCE_SYNC_TICKS = 300

local tuning_cache = nil
local tuning_cache_tick = -1

local function get_global_setting(name, default)
  if settings and settings.global and settings.global[name] and settings.global[name].value ~= nil then
    return settings.global[name].value
  end
  return default
end

local function read_global_tuning()
  return {
    patrol_follow_min_distance = get_global_setting("battleship-patrol-follow-min-distance", DEFAULT_PATROL_FOLLOW_MIN_DISTANCE),
    patrol_follow_max_distance = get_global_setting("battleship-patrol-follow-max-distance", DEFAULT_PATROL_FOLLOW_MAX_DISTANCE),
    patrol_follow_step = get_global_setting("battleship-patrol-follow-step", DEFAULT_PATROL_FOLLOW_STEP),
    escort_update_ticks = get_global_setting("battleship-escort-update-ticks", DEFAULT_ESCORT_UPDATE_TICKS),
    escort_min_separation_tiles = get_global_setting("battleship-escort-min-separation-tiles", DEFAULT_ESCORT_MIN_SEPARATION_TILES),
    escort_avoid_strength = get_global_setting("battleship-escort-avoid-strength", DEFAULT_ESCORT_AVOID_STRENGTH),
    battleship_ammo_refill_ticks = get_global_setting("battleship-ammo-refill-ticks", DEFAULT_BATTLESHIP_AMMO_REFILL_TICKS),
    patrol_ammo_refill_ticks = get_global_setting("patrol-boat-ammo-refill-ticks", DEFAULT_PATROL_AMMO_REFILL_TICKS),
    radar_chart_ticks = get_global_setting("battleship-radar-chart-ticks", DEFAULT_RADAR_CHART_TICKS),
    radar_min_move_for_rechart = get_global_setting("battleship-radar-min-move-for-rechart", DEFAULT_RADAR_MIN_MOVE_FOR_RECHART),
    force_sync_ticks = get_global_setting("battleship-force-sync-ticks", DEFAULT_FORCE_SYNC_TICKS),
  }
end

local function tuning_for_player(_player)
  local tick = (game and game.tick) or -1
  if (not tuning_cache) or tuning_cache_tick ~= tick then
    tuning_cache = read_global_tuning()
    tuning_cache_tick = tick
  end
  return tuning_cache
end

local function invalidate_tuning_cache()
  tuning_cache = nil
  tuning_cache_tick = -1
end

local function player_by_index(player_index)
  if not (player_index and game and game.players) then return nil end
  local pp = game.players[player_index]
  if pp and pp.valid then return pp end
  return nil
end

local function entry_owner_player(entry)
  if entry and entry.owner_player_index then
    local pp = player_by_index(entry.owner_player_index)
    if pp then return pp end
  end
  local ship = entry and entry.ship
  if ship and ship.valid then
    local ok, lu = pcall(function() return ship.last_user end)
    if ok and lu and lu.valid then return lu end
  end
  return nil
end

-- Movement detection tuning
-- cargo-ships can report tiny speed jitter around 0, so we use hysteresis + debounce.
local STOP_SPEED_EPS = 0.01           -- enter stopped candidate when |speed| < this
local MOVE_SPEED_EPS = 0.03           -- leave stopped mode only when |speed| >= this
local STOP_STABLE_TICKS = 30          -- consecutive ticks required to enable auto targeting
local MOVE_STABLE_TICKS = 10          -- consecutive ticks required to disable auto targeting

-- Some cargo-ships/pelagos setups may use slightly different entity names.
-- We accept exact names AND any entity name that contains these tokens.
local function is_battleship_name(name)
  if not name then return false end
  if name == BATTLESHIP_NAME or name == INDEP_BATTLESHIP_NAME then return true end
  return string.find(name, "battleship", 1, true) ~= nil
end

local function is_patrol_boat_name(name)
  if not name then return false end
  if name == PATROL_BOAT_NAME or name == INDEP_PATROL_BOAT_NAME then return true end
  if string.find(name, "patrol", 1, true) ~= nil and string.find(name, "boat", 1, true) ~= nil then return true end
  return string.find(name, "patrol-boat", 1, true) ~= nil
end

local function is_aircraft_carrier_name(name)
  if not name then return false end
  if name == AIRCRAFT_CARRIER_NAME or name == INDEP_AIRCRAFT_CARRIER_NAME then return true end
  if string.find(name, "aircraft-carrier", 1, true) ~= nil then return true end
  return string.find(name, "aircraft", 1, true) ~= nil and string.find(name, "carrier", 1, true) ~= nil
end

local function is_ship_name(name)
  return is_battleship_name(name) or is_aircraft_carrier_name(name) or is_patrol_boat_name(name)
end

-- How often we do an expensive fallback scan for ships that were created without build events.
local FALLBACK_SCAN_TICKS = 600 -- every 10 seconds

local CONVERSION_RESCAN_DELAYS = {10, 30, 90} -- ticks after build to catch cargo-ships replacement
local CONVERSION_RESCAN_RADIUS = 33

local turret_names = {
  "battleship-cannon-1",
  "battleship-cannon-2",
  "battleship-cannon-3",
  "battleship-cannon-4",
}

local turret_offsets = {
  {x = 0, y = -6},
  {x = 0, y = -2},
  {x = 0, y = 3},
  {x = 0, y = 7},
}

local patrol_turret_offsets = {
  {x = 0, y = 0},
}

local aircraft_carrier_roboport_offsets = {
  {x = 0.0, y = -5.5},
  {x = 0.0, y = -2.0},
}

local aircraft_carrier_landing_pad_offset = {x = 0, y = 4.5}
local aircraft_carrier_power_offset = {x = 0, y = 0}
local aircraft_carrier_smoke_offsets = {
  {x = -0.75, y = 7.5},
  {x = 0.75, y = 7.5},
}
local AIRCRAFT_CARRIER_POWER_BUFFER = 200000000
local AIRCRAFT_CARRIER_SMOKE_INTERVAL = 12
local AIRCRAFT_CARRIER_GENERATOR_EFFICIENCY = 10
local AIRCRAFT_CARRIER_ROBOT_NAMES = {
  ["construction-robot"] = true,
  ["logistic-robot"] = true,
}

local BATTLESHIP_TURRET_PROXY_SPRITE = "__base__/graphics/icons/artillery-turret.png"
local BATTLESHIP_TURRET_PROXY_SCALE = 0.55
local PATROL_TURRET_PROXY_SPRITE = "__base__/graphics/icons/rocket-launcher.png"
local PATROL_TURRET_PROXY_SCALE = 0.45
local AIRCRAFT_CARRIER_ROBOPORT_VISUAL_NAME = "aircraft-carrier-roboport-visual"
local AIRCRAFT_CARRIER_LANDING_PAD_VISUAL_NAME = "aircraft-carrier-landing-pad-visual"
local create_support_entity_at
local get_aircraft_carrier_landing_pad_inventory

local function rotate_offset(offset, orientation)
  local angle = orientation * 2 * math.pi
  local cos_angle = math.cos(angle)
  local sin_angle = math.sin(angle)
  return {
    x = offset.x * cos_angle - offset.y * sin_angle,
    y = offset.x * sin_angle + offset.y * cos_angle,
  }
end

local function snap05(v)
  return math.floor(v * 2 + 0.5) / 2
end

local function sync_turret_direction(entry, turret, ship)
  if not (turret and turret.valid and ship and ship.valid) then return end
  local desired = ship.direction
  if turret.direction == desired then return end

  if entry._turret_direction_sync_supported == false then
    return
  end

  if entry._turret_direction_sync_supported == true then
    turret.direction = desired
    return
  end

  local ok = pcall(function()
    turret.direction = desired
  end)
  entry._turret_direction_sync_supported = ok
  if not ok then
    dbg("[Battleship] turret.direction sync unsupported for " .. tostring(turret.name))
  end
end

local function sync_turret_position(entry, turret, target_x, target_y)
  local current = turret.position
  local dx = target_x - current.x
  local dy = target_y - current.y
  if (dx * dx + dy * dy) <= 1e-6 then
    return false
  end

  if entry._turret_exact_teleport_supported ~= false then
    local ok_exact = turret.teleport({target_x, target_y})
    if ok_exact then
      entry._turret_exact_teleport_supported = true
      return true
    end
    entry._turret_exact_teleport_supported = false
  end

  local snapped_x = snap05(target_x)
  local snapped_y = snap05(target_y)
  local snapped_dx = snapped_x - current.x
  local snapped_dy = snapped_y - current.y
  if (snapped_dx * snapped_dx + snapped_dy * snapped_dy) <= 1e-6 then
    return false
  end

  return turret.teleport({snapped_x, snapped_y}) or false
end

local function destroy_battleship_turret_visuals(entry)
  if not (entry and entry.visual_turrets and rendering) then return end
  for index, id in pairs(entry.visual_turrets) do
    if id and rendering.is_valid(id) then
      rendering.destroy(id)
    end
    entry.visual_turrets[index] = nil
  end
end

local function ensure_battleship_turret_visual(entry, index, ship, x, y, orientation)
  if not (rendering and ship and ship.valid) then return end
  entry.visual_turrets = entry.visual_turrets or {}

  local id = entry.visual_turrets[index]
  if not (id and rendering.is_valid(id)) then
    local ok, new_id = pcall(function()
      return rendering.draw_sprite{
        sprite = BATTLESHIP_TURRET_PROXY_SPRITE,
        surface = ship.surface,
        target = {x = x, y = y},
        orientation = orientation,
        x_scale = BATTLESHIP_TURRET_PROXY_SCALE,
        y_scale = BATTLESHIP_TURRET_PROXY_SCALE,
        render_layer = "object",
      }
    end)
    if not ok then
      dbg("[Battleship] rendering.draw_sprite failed for proxy turret " .. tostring(index))
      return
    end
    id = new_id
    entry.visual_turrets[index] = id
    return
  end

  local ok_target = pcall(function()
    rendering.set_target(id, {x = x, y = y})
  end)
  local ok_orientation = pcall(function()
    rendering.set_orientation(id, orientation)
  end)
  if not (ok_target and ok_orientation) then
    if rendering.is_valid(id) then
      rendering.destroy(id)
    end
    entry.visual_turrets[index] = nil
  end
end

local function destroy_patrol_turret_visual(entry)
  if not (entry and entry.visual_turret and rendering) then return end
  if rendering.is_valid(entry.visual_turret) then
    rendering.destroy(entry.visual_turret)
  end
  entry.visual_turret = nil
end

local function ensure_patrol_turret_visual(entry, ship, x, y, orientation)
  if not (rendering and ship and ship.valid) then return end

  local id = entry.visual_turret
  if not (id and rendering.is_valid(id)) then
    local ok, new_id = pcall(function()
      return rendering.draw_sprite{
        sprite = PATROL_TURRET_PROXY_SPRITE,
        surface = ship.surface,
        target = {x = x, y = y},
        orientation = orientation,
        x_scale = PATROL_TURRET_PROXY_SCALE,
        y_scale = PATROL_TURRET_PROXY_SCALE,
        render_layer = "object",
      }
    end)
    if not ok then
      dbg("[Battleship] rendering.draw_sprite failed for patrol proxy")
      return
    end
    entry.visual_turret = new_id
    return
  end

  local ok_target = pcall(function()
    rendering.set_target(id, {x = x, y = y})
  end)
  local ok_orientation = pcall(function()
    rendering.set_orientation(id, orientation)
  end)
  if not (ok_target and ok_orientation) then
    if rendering.is_valid(id) then
      rendering.destroy(id)
    end
    entry.visual_turret = nil
  end
end

local function destroy_aircraft_carrier_component_visuals(entry)
  if not entry then return end

  if entry.visual_roboports then
    for index, visual in pairs(entry.visual_roboports) do
      if type(visual) == "number" then
        if rendering.is_valid(visual) then
          rendering.destroy(visual)
        end
      elseif visual and visual.valid then
        visual.destroy()
      end
      entry.visual_roboports[index] = nil
    end
  end

  if type(entry.visual_landing_pad) == "number" then
    if rendering.is_valid(entry.visual_landing_pad) then
      rendering.destroy(entry.visual_landing_pad)
    end
  elseif entry.visual_landing_pad and entry.visual_landing_pad.valid then
    entry.visual_landing_pad.destroy()
  end
  entry.visual_landing_pad = nil
end

local function ensure_aircraft_carrier_visual_entity(container, key, ship, x, y, entity_name)
  if not (ship and ship.valid and container and entity_name) then return end

  local visual = container[key]
  if type(visual) == "number" then
    if rendering and rendering.is_valid(visual) then
      rendering.destroy(visual)
    end
    visual = nil
    container[key] = nil
  end

  if visual and visual.valid and visual.name ~= entity_name then
    visual.destroy()
    visual = nil
    container[key] = nil
  end

  if not (visual and visual.valid) then
    visual = create_support_entity_at(ship.surface, ship.force, ship.direction, entity_name, {x = x, y = y}, false)
    if not (visual and visual.valid) then
      dbg("[Battleship] create_entity failed for aircraft carrier visual " .. tostring(entity_name))
      return
    end
    container[key] = visual
    return
  end

  if visual.force ~= ship.force then
    pcall(function()
      visual.force = ship.force
    end)
  end

  local current = visual.position
  local dx = x - current.x
  local dy = y - current.y
  if (dx * dx + dy * dy) > 1e-6 then
    visual.teleport({x = x, y = y})
  end
end

local function get_radar_range(ship_name)
  if is_battleship_name(ship_name) then
    return settings.global["battleship-radar-range"].value
  end
  if is_aircraft_carrier_name(ship_name) then
    return settings.global["battleship-radar-range"].value
  end
  if is_patrol_boat_name(ship_name) then
    return settings.global["patrol-boat-radar-range"].value
  end
  return 0
end

local function ensure_globals()
  if not storage then storage = {} end
  if global then
    global.escort = global.escort or {boats = {}, targets = {}}
    storage.escort = global.escort
  end
  storage.battleships = storage.battleships or {}
  storage.aircraft_carriers = storage.aircraft_carriers or {}
  storage.patrol_boats = storage.patrol_boats or {}
  storage.patrol_selections = storage.patrol_selections or {}
  storage.escort = storage.escort or {boats = {}, targets = {}}
  storage.scan_state = storage.scan_state or {surface_index = 1, deep_counter = 0}
  storage.pending_rescans = storage.pending_rescans or {}
end

local function register_ships()
  local iface = remote.interfaces and remote.interfaces["cargo-ships"]
  if not iface then return end

  if iface.add_ship then
    local ok1, err1 = pcall(function()
      remote.call("cargo-ships", "add_ship", {
        name = BATTLESHIP_NAME,
        engine = AIRCRAFT_CARRIER_ENGINE_NAME,
        engine_scale = 1,
        engine_at_front = false,
      })
    end)
    if not ok1 then dbg("[Battleship] add_ship failed for battleship: " .. tostring(err1)) end

    local ok1b, err1b = pcall(function()
      remote.call("cargo-ships", "add_ship", {
        name = AIRCRAFT_CARRIER_NAME,
        engine = AIRCRAFT_CARRIER_ENGINE_NAME,
        engine_scale = 1,
        engine_at_front = false,
      })
    end)
    if not ok1b then dbg("[Battleship] add_ship failed for aircraft-carrier: " .. tostring(err1b)) end

    local ok2, err2 = pcall(function()
      remote.call("cargo-ships", "add_ship", {
        name = PATROL_BOAT_NAME,
        engine = "boat_engine",
        engine_scale = 0.3,
        engine_at_front = true,
      })
    end)
    if not ok2 then dbg("[Battleship] add_ship failed for patrol-boat: " .. tostring(err2)) end
  end

  if iface.add_boat then
    local ok3, err3 = pcall(function()
      remote.call("cargo-ships", "add_boat", {
        name = INDEP_BATTLESHIP_NAME,
        -- Match patrol-boat behavior: when built on waterway, spawn rail ship;
        -- when built off waterway, keep freely-drivable independent variant.
        rail_version = BATTLESHIP_NAME,
      })
    end)
    if not ok3 then dbg("[Battleship] add_boat failed for indep-battleship: " .. tostring(err3)) end

    local ok3b, err3b = pcall(function()
      remote.call("cargo-ships", "add_boat", {
        name = INDEP_AIRCRAFT_CARRIER_NAME,
        rail_version = AIRCRAFT_CARRIER_NAME,
      })
    end)
    if not ok3b then dbg("[Battleship] add_boat failed for indep-aircraft-carrier: " .. tostring(err3b)) end

    local ok4, err4 = pcall(function()
      remote.call("cargo-ships", "add_boat", {
        name = INDEP_PATROL_BOAT_NAME,
        rail_version = PATROL_BOAT_NAME,
      })
    end)
    if not ok4 then dbg("[Battleship] add_boat failed for indep-patrol-boat: " .. tostring(err4)) end
  end
end

local init_existing
local fallback_scan_step
local is_stopped
local on_visual_tick

-- Declare these as locals so they are callable before assignment, and don't leak globals.
local queue_conversion_rescans
local process_pending_rescans

-- Post-load initialization: on_load cannot safely use game state for scanning.
-- We schedule a one-time scan on the next tick after a save is loaded.
local function post_load_init()
  ensure_globals()
  init_existing()
  dbg("[Battleship] post_load_init finished")
  -- Restore the visual sync handler if we temporarily used tick=1 for post-load init.
  if VISUAL_SYNC_NTH_TICK == 1 then
    script.on_nth_tick(1, on_visual_tick)
  else
    -- run once
    script.on_nth_tick(1, nil)
  end
end

local function create_turret(ship, turret_name, offset)
  local rotated_offset = rotate_offset(offset, ship.orientation)
  local pos = {
    x = snap05(ship.position.x + rotated_offset.x),
    y = snap05(ship.position.y + rotated_offset.y)
  }

  local can, reason = ship.surface.can_place_entity{
    name = turret_name,
    position = pos,
    force = ship.force
  }

  if not can then
    dbg("[Battleship] cannot place " .. turret_name .. " at " .. pos.x .. "," .. pos.y .. " reason=" .. tostring(reason))
    return nil
  end

  local turret = ship.surface.create_entity{
    name = turret_name,
    position = pos,
    force = ship.force,
    direction = ship.direction,
    build_check_type = defines.build_check_type.manual,
    create_build_effect_smoke = false,
  }

  if not turret then
    dbg("[Battleship] create_entity failed for " .. turret_name .. " at " .. pos.x .. "," .. pos.y)
    return nil
  end

  turret.operable = false

  -- Ensure the turret AI is allowed to run.
  -- For artillery we also toggle auto-targeting + active based on movement.
  if turret.type == "artillery-turret" then
    -- Default OFF until debounce logic enables it after the ship is truly stopped.
    turret.artillery_auto_targeting = false
    turret.active = false
  else
    turret.active = true
  end

  dbg("[Battleship] placed " .. turret_name .. " at " .. pos.x .. "," .. pos.y)
  return turret
end

local function destroy_turrets(entry)
  destroy_battleship_turret_visuals(entry)
  if entry and entry.turrets then
    for _, turret in pairs(entry.turrets) do
      if turret and turret.valid then
        turret.destroy()
      end
    end
  end
end

local function destroy_patrol_turret(entry)
  destroy_patrol_turret_visual(entry)
  if entry and entry.turret and entry.turret.valid then
    entry.turret.destroy()
  end
  if entry then
    entry.turret = nil
  end
end

local function sync_entity_direction(entity, ship)
  if not (entity and entity.valid and ship and ship.valid) then return end
  pcall(function()
    entity.direction = ship.direction
  end)
end

local function get_offset_world_position(ship, offset)
  local rotated_offset = rotate_offset(offset, ship.orientation)
  return {
    x = snap05(ship.position.x + rotated_offset.x),
    y = snap05(ship.position.y + rotated_offset.y)
  }
end

create_support_entity_at = function(surface, force, direction, entity_name, position, keep_operable)
  if not (surface and surface.valid and force and position and entity_name) then
    return nil
  end

  local can, reason = surface.can_place_entity{
    name = entity_name,
    position = position,
    force = force
  }

  if not can then
    dbg("[Battleship] cannot place " .. entity_name .. " at " .. position.x .. "," .. position.y .. " reason=" .. tostring(reason))
    return nil
  end

  local entity = surface.create_entity{
    name = entity_name,
    position = position,
    force = force,
    direction = direction,
    build_check_type = defines.build_check_type.manual,
    create_build_effect_smoke = false,
  }

  if not entity then
    dbg("[Battleship] create_entity failed for " .. entity_name .. " at " .. position.x .. "," .. position.y)
    return nil
  end

  pcall(function() entity.destructible = false end)
  pcall(function() entity.minable = false end)
  pcall(function() entity.rotatable = false end)
  if keep_operable == false then
    pcall(function() entity.operable = false end)
  end
  if entity.type ~= "electric-energy-interface" then
    pcall(function() entity.active = true end)
  end

  return entity
end

local function create_attached_entity(ship, entity_name, offset, keep_operable)
  local position = get_offset_world_position(ship, offset)
  return create_support_entity_at(ship.surface, ship.force, ship.direction, entity_name, position, keep_operable)
end

local function get_optional_inventory(entity, inventory_id)
  if not (entity and entity.valid and inventory_id) then return nil end
  local ok, inventory = pcall(function()
    return entity.get_inventory(inventory_id)
  end)
  if ok then
    return inventory
  end
  return nil
end

local function stack_quality_name(stack)
  if not stack then return nil end
  local quality = stack.quality
  if type(quality) == "table" then
    local ok, name = pcall(function() return quality.name end)
    if ok then return name end
  end
  return quality
end

local function make_stack_request(stack, count)
  if not (stack and stack.valid_for_read) then return nil end
  local request = {
    name = stack.name,
    count = count or stack.count
  }
  local quality = stack_quality_name(stack)
  if quality then
    request.quality = quality
  end
  return request
end

local function get_stack_fuel_value(stack)
  if not (stack and stack.valid_for_read) then return 0 end
  local prototype = prototypes and prototypes.item and prototypes.item[stack.name]
  local fuel_value = prototype and prototype.fuel_value or 0
  if type(fuel_value) ~= "number" then
    return 0
  end
  return fuel_value
end

local function is_fuel_stack(stack)
  return get_stack_fuel_value(stack) > 0
end

local function inventory_contains_fuel(inventory)
  if not inventory then
    return false
  end

  for i = 1, #inventory do
    local stack = inventory[i]
    if stack and stack.valid_for_read and is_fuel_stack(stack) then
      return true
    end
  end

  return false
end

local function move_inventory_stacks(source_inventory, target_inventory, predicate)
  if not (source_inventory and target_inventory) then
    return 0
  end

  local moved = 0
  for i = 1, #source_inventory do
    local stack = source_inventory[i]
    if stack and stack.valid_for_read and (not predicate or predicate(stack)) then
      local request = make_stack_request(stack)
      if request then
        local inserted = target_inventory.insert(request)
        if inserted and inserted > 0 then
          source_inventory.remove(make_stack_request(stack, inserted))
          moved = moved + inserted
        end
      end
    end
  end

  return moved
end

local function recover_inventory_contents(source_inventory, target_inventory, surface, position, force)
  if not source_inventory then
    return
  end

  for i = 1, #source_inventory do
    local stack = source_inventory[i]
    if stack and stack.valid_for_read then
      local request = make_stack_request(stack)
      if request then
        local inserted = target_inventory and target_inventory.insert(request) or 0
        if inserted and inserted > 0 then
          source_inventory.remove(make_stack_request(stack, inserted))
        end

        local remaining = request.count - (inserted or 0)
        if remaining > 0 then
          local spill_request = make_stack_request(stack, remaining)
          if surface and surface.valid and position and spill_request then
            surface.spill_item_stack{
              position = position,
              stack = spill_request,
              enable_looted = true,
              force = force
            }
          end
          source_inventory.remove(spill_request)
        end
      end
    end
  end
end

local function get_ship_cargo_inventory(ship)
  if not (ship and ship.valid) then
    return nil
  end
  if ship.type == "car" then
    return get_optional_inventory(ship, defines.inventory.car_trunk)
  end
  return get_optional_inventory(ship, defines.inventory.cargo_wagon)
end

local function get_ship_engine(ship, expected_name)
  if not (ship and ship.valid) then
    return nil
  end

  local directions = {defines.rail_direction.front, defines.rail_direction.back}
  for _, rail_direction in ipairs(directions) do
    local ok, rolling_stock = pcall(function()
      return ship.get_connected_rolling_stock(rail_direction)
    end)
    if ok and rolling_stock and rolling_stock.valid and rolling_stock ~= ship then
      if (not expected_name) or rolling_stock.name == expected_name then
        return rolling_stock
      end
    end
  end

  local train = ship.train
  if train then
    local candidates = {train.front_stock, train.back_stock}
    for _, candidate in ipairs(candidates) do
      if candidate and candidate.valid and candidate ~= ship then
        if (not expected_name) or candidate.name == expected_name then
          return candidate
        end
      end
    end
  end

  return nil
end

local get_ship_burner

local function get_carrier_fuel_inventory(entry)
  local ship = entry and entry.ship
  if not (ship and ship.valid) then
    return nil
  end

  local burner = get_ship_burner(ship)
  if burner then
    local ok_inventory, inventory = pcall(function()
      return burner.inventory
    end)
    if ok_inventory and inventory and inventory_contains_fuel(inventory) then
      return inventory
    end

    local ok_fuel_inventory, fuel_inventory = pcall(function()
      return burner.get_inventory(defines.inventory.fuel)
    end)
    if ok_fuel_inventory and fuel_inventory and inventory_contains_fuel(fuel_inventory) then
      return fuel_inventory
    end
  end

  local cargo_inventory = get_ship_cargo_inventory(ship)
  if inventory_contains_fuel(cargo_inventory) then
    return cargo_inventory
  end

  local landing_pad_inventory = get_aircraft_carrier_landing_pad_inventory(entry)
  if inventory_contains_fuel(landing_pad_inventory) then
    return landing_pad_inventory
  end

  return nil
end

get_ship_burner = function(ship)
  if not (ship and ship.valid) then
    return nil
  end

  if ship.type == "car" then
    return ship.burner
  end

  local engine = get_ship_engine(ship, AIRCRAFT_CARRIER_ENGINE_NAME)
  return engine and engine.burner or nil
end

local function get_carrier_anchor(entry)
  local ship = entry and entry.ship
  if ship and ship.valid then
    return ship.surface, ship.position, ship.force
  end

  if entry and entry.landing_pad and entry.landing_pad.valid then
    return entry.landing_pad.surface, entry.landing_pad.position, entry.landing_pad.force
  end

  if entry and entry.roboports then
    for _, roboport in pairs(entry.roboports) do
      if roboport and roboport.valid then
        return roboport.surface, roboport.position, roboport.force
      end
    end
  end

  if entry and entry.request_proxy and entry.request_proxy.valid then
    return entry.request_proxy.surface, entry.request_proxy.position, entry.request_proxy.force
  end

  if entry and entry.power_interface and entry.power_interface.valid then
    return entry.power_interface.surface, entry.power_interface.position, entry.power_interface.force
  end

  return nil, nil, nil
end

get_aircraft_carrier_landing_pad_inventory = function(entry)
  if not (entry and entry.landing_pad and entry.landing_pad.valid) then
    return nil
  end
  return get_optional_inventory(entry.landing_pad, defines.inventory.chest)
end

local function get_aircraft_carrier_request_proxy_inventory(entry)
  if not (entry and entry.request_proxy and entry.request_proxy.valid) then
    return nil
  end
  return get_optional_inventory(entry.request_proxy, defines.inventory.chest)
end

local function get_logistic_point(entity)
  if not (entity and entity.valid) then
    return nil
  end
  local ok, point = pcall(function()
    return entity.get_logistic_point(defines.logistic_member_index.logistic_container)
  end)
  if ok then
    return point
  end
  return nil
end

local function get_logistic_section(point)
  if not point then
    return nil
  end

  local ok_section, section = pcall(function()
    return point.get_section(1)
  end)
  if ok_section and section and section.valid then
    return section
  end

  local ok_add, new_section = pcall(function()
    return point.add_section()
  end)
  if ok_add and new_section and new_section.valid then
    return new_section
  end

  return nil
end

local function copy_logistic_requests(source_entity, target_entity)
  local source_point = get_logistic_point(source_entity)
  local target_point = get_logistic_point(target_entity)
  if not (source_point and target_point) then
    return
  end

  local target_section = get_logistic_section(target_point)
  if not target_section then
    return
  end

  local source_filters = source_point.filters or {}
  local slot_index = 1
  for _, filter in pairs(source_filters) do
    local request = nil
    if filter and filter.value then
      request = {
        value = filter.value,
        min = filter.min or filter.count or 0
      }
    elseif filter and filter.name then
      local value = {name = filter.name}
      if filter.quality then
        value.quality = filter.quality
      end
      request = {
        value = value,
        min = filter.count or filter.min or 0
      }
    end

    if request and request.min and request.min > 0 then
      target_section.set_slot(slot_index, request)
      slot_index = slot_index + 1
    end
  end

  for i = slot_index, target_section.filters_count do
    target_section.clear_slot(i)
  end

  local ok_request_from_buffers, request_from_buffers = pcall(function()
    return source_entity.request_from_buffers
  end)
  if ok_request_from_buffers then
    pcall(function()
      target_entity.request_from_buffers = request_from_buffers
    end)
  end
end

local function destroy_aircraft_carrier_components(entry, recover_to_ship)
  if not entry then
    return
  end

  destroy_aircraft_carrier_component_visuals(entry)

  local surface, position, force = get_carrier_anchor(entry)
  local ship_inventory = nil
  if recover_to_ship and entry.ship and entry.ship.valid then
    ship_inventory = get_ship_cargo_inventory(entry.ship)
  end

  if entry.landing_pad and entry.landing_pad.valid then
    recover_inventory_contents(get_aircraft_carrier_landing_pad_inventory(entry), ship_inventory, surface, position, force)
    entry.landing_pad.destroy()
  end
  entry.landing_pad = nil

  if entry.request_proxy and entry.request_proxy.valid then
    recover_inventory_contents(get_aircraft_carrier_request_proxy_inventory(entry), ship_inventory, surface, position, force)
    entry.request_proxy_position = {
      x = entry.request_proxy.position.x,
      y = entry.request_proxy.position.y
    }
    entry.request_proxy.destroy()
  end
  entry.request_proxy = nil
  entry.request_proxy_rebuild = nil

  if entry.roboports then
    for index, roboport in pairs(entry.roboports) do
      if roboport and roboport.valid then
        recover_inventory_contents(get_optional_inventory(roboport, defines.inventory.roboport_robot), ship_inventory, surface, position, force)
        recover_inventory_contents(get_optional_inventory(roboport, defines.inventory.roboport_material), ship_inventory, surface, position, force)
        roboport.destroy()
      end
      entry.roboports[index] = nil
    end
  end

  if entry.power_interface and entry.power_interface.valid then
    entry.power_interface.destroy()
  end
  entry.power_interface = nil

  if entry.power_pole and entry.power_pole.valid then
    entry.power_pole.destroy()
  end
  entry.power_pole = nil
end

local function sync_aircraft_carrier_components(entry)
  local ship = entry.ship
  if not (ship and ship.valid) then
    return
  end

  local tp = tuning_for_player(entry_owner_player(entry))
  entry.roboports = entry.roboports or {}
  entry.visual_roboports = entry.visual_roboports or {}
  entry._last_carrier_ship_x = entry._last_carrier_ship_x or ship.position.x
  entry._last_carrier_ship_y = entry._last_carrier_ship_y or ship.position.y
  entry._last_carrier_ship_orientation = entry._last_carrier_ship_orientation or ship.orientation

  local dxs = ship.position.x - entry._last_carrier_ship_x
  local dys = ship.position.y - entry._last_carrier_ship_y
  local dor = ship.orientation - entry._last_carrier_ship_orientation
  local ship_moved = (dxs * dxs + dys * dys) > 1e-6 or math.abs(dor) > 1e-6
  if ship_moved then
    entry._last_carrier_ship_x = ship.position.x
    entry._last_carrier_ship_y = ship.position.y
    entry._last_carrier_ship_orientation = ship.orientation
  end

  for index, offset in ipairs(aircraft_carrier_roboport_offsets) do
    local roboport = entry.roboports[index]
    if not (roboport and roboport.valid) then
      roboport = create_attached_entity(ship, AIRCRAFT_CARRIER_ROBOPORT_NAME, offset, true)
      entry.roboports[index] = roboport
    end
    if roboport and roboport.valid then
      local rotated = rotate_offset(offset, ship.orientation)
      if ship_moved then
        sync_turret_position(entry, roboport, ship.position.x + rotated.x, ship.position.y + rotated.y)
        sync_entity_direction(roboport, ship)
      end
      if ship_moved or (not entry._last_carrier_force_sync_tick) or ((game.tick - entry._last_carrier_force_sync_tick) >= tp.force_sync_ticks) then
        roboport.force = ship.force
      end
      ensure_aircraft_carrier_visual_entity(
        entry.visual_roboports,
        index,
        ship,
        ship.position.x + rotated.x,
        ship.position.y + rotated.y,
        AIRCRAFT_CARRIER_ROBOPORT_VISUAL_NAME
      )
    end
  end

  if not (entry.landing_pad and entry.landing_pad.valid) then
    entry.landing_pad = create_attached_entity(ship, AIRCRAFT_CARRIER_LANDING_PAD_NAME, aircraft_carrier_landing_pad_offset, true)
  end
  if entry.landing_pad and entry.landing_pad.valid then
    local rotated = rotate_offset(aircraft_carrier_landing_pad_offset, ship.orientation)
    if ship_moved then
      sync_turret_position(entry, entry.landing_pad, ship.position.x + rotated.x, ship.position.y + rotated.y)
      sync_entity_direction(entry.landing_pad, ship)
    end
    if ship_moved or (not entry._last_carrier_force_sync_tick) or ((game.tick - entry._last_carrier_force_sync_tick) >= tp.force_sync_ticks) then
      entry.landing_pad.force = ship.force
    end
    entry.visual_landing_pad = entry.visual_landing_pad or nil
    ensure_aircraft_carrier_visual_entity(
      entry,
      "visual_landing_pad",
      ship,
      ship.position.x + rotated.x,
      ship.position.y + rotated.y,
      AIRCRAFT_CARRIER_LANDING_PAD_VISUAL_NAME
    )
  end

  local landing_pad_inventory = get_aircraft_carrier_landing_pad_inventory(entry)
  if entry.request_proxy and entry.request_proxy.valid then
    recover_inventory_contents(
      get_aircraft_carrier_request_proxy_inventory(entry),
      landing_pad_inventory,
      ship.surface,
      ship.position,
      ship.force
    )
    entry.request_proxy.destroy()
    entry.request_proxy = nil
  end
  entry.request_proxy = nil
  entry.request_proxy_position = nil
  entry.request_proxy_rebuild = nil

  if not (entry.power_pole and entry.power_pole.valid) then
    entry.power_pole = create_attached_entity(ship, AIRCRAFT_CARRIER_POWER_POLE_NAME, aircraft_carrier_power_offset, false)
  end
  if entry.power_pole and entry.power_pole.valid and ship_moved then
    local rotated = rotate_offset(aircraft_carrier_power_offset, ship.orientation)
    sync_turret_position(entry, entry.power_pole, ship.position.x + rotated.x, ship.position.y + rotated.y)
  end

  if not (entry.power_interface and entry.power_interface.valid) then
    entry.power_interface = create_attached_entity(ship, AIRCRAFT_CARRIER_POWER_INTERFACE_NAME, aircraft_carrier_power_offset, false)
  end
  if entry.power_interface and entry.power_interface.valid then
    if ship_moved then
      local rotated = rotate_offset(aircraft_carrier_power_offset, ship.orientation)
      sync_turret_position(entry, entry.power_interface, ship.position.x + rotated.x, ship.position.y + rotated.y)
    end
    if ship_moved or (not entry._last_carrier_force_sync_tick) or ((game.tick - entry._last_carrier_force_sync_tick) >= tp.force_sync_ticks) then
      entry.power_interface.force = ship.force
      if entry.power_pole and entry.power_pole.valid then
        entry.power_pole.force = ship.force
      end
      entry._last_carrier_force_sync_tick = game.tick
    end
  end
end

local function sync_aircraft_carrier_request_proxy(entry)
  local landing_pad = entry.landing_pad
  local request_proxy = entry.request_proxy
  if not (landing_pad and landing_pad.valid and request_proxy and request_proxy.valid) then
    return
  end

  copy_logistic_requests(landing_pad, request_proxy)
end

local function transfer_aircraft_carrier_proxy_cargo(entry)
  local request_proxy_inventory = get_aircraft_carrier_request_proxy_inventory(entry)
  local landing_pad_inventory = get_aircraft_carrier_landing_pad_inventory(entry)
  if not (request_proxy_inventory and landing_pad_inventory) then
    return
  end

  move_inventory_stacks(request_proxy_inventory, landing_pad_inventory)
end

local function transfer_aircraft_carrier_cargo(entry)
  local ship = entry.ship
  local ship_inventory = get_ship_cargo_inventory(ship)
  local landing_pad_inventory = get_aircraft_carrier_landing_pad_inventory(entry)
  if not (ship_inventory and landing_pad_inventory) then
    return
  end

  move_inventory_stacks(ship_inventory, landing_pad_inventory, function(stack)
    return not is_fuel_stack(stack)
  end)
end

local function load_aircraft_carrier_roboports(entry)
  local landing_pad_inventory = get_aircraft_carrier_landing_pad_inventory(entry)
  if not landing_pad_inventory then
    return
  end

  for _, roboport in pairs(entry.roboports or {}) do
    if roboport and roboport.valid then
      local robot_inventory = get_optional_inventory(roboport, defines.inventory.roboport_robot)
      if robot_inventory then
        move_inventory_stacks(landing_pad_inventory, robot_inventory, function(stack)
          return AIRCRAFT_CARRIER_ROBOT_NAMES[stack.name] == true
        end)
      end
    end
  end
end

local function consume_one_fuel_item(ship, fuel_inventory)
  local burner = get_ship_burner(ship)
  if burner then
    local ok_remaining, remaining = pcall(function()
      return burner.remaining_burning_fuel
    end)
    if ok_remaining and remaining and remaining > 0 then
      local ok_consume = pcall(function()
        burner.remaining_burning_fuel = 0
      end)
      if ok_consume then
        return remaining * AIRCRAFT_CARRIER_GENERATOR_EFFICIENCY
      end
    end
  end

  if not fuel_inventory then
    return 0
  end

  for i = 1, #fuel_inventory do
    local stack = fuel_inventory[i]
    if stack and stack.valid_for_read then
      local fuel_value = get_stack_fuel_value(stack)
      if fuel_value > 0 then
        fuel_inventory.remove(make_stack_request(stack, 1))
        return fuel_value * AIRCRAFT_CARRIER_GENERATOR_EFFICIENCY
      end
    end
  end

  return 0
end

local function emit_aircraft_carrier_generation_smoke(entry)
  local ship = entry and entry.ship
  if not (ship and ship.valid and ship.surface and ship.surface.valid) then
    return
  end

  if entry._last_carrier_generation_smoke_tick and (game.tick - entry._last_carrier_generation_smoke_tick) < AIRCRAFT_CARRIER_SMOKE_INTERVAL then
    return
  end
  entry._last_carrier_generation_smoke_tick = game.tick

  for _, offset in ipairs(aircraft_carrier_smoke_offsets) do
    local position = get_offset_world_position(ship, offset)
    local ok = pcall(function()
      ship.surface.create_trivial_smoke{
        name = "car-smoke",
        position = position,
      }
    end)
    if not ok then
      pcall(function()
        ship.surface.create_entity{
          name = "car-smoke",
          position = position,
        }
      end)
    end
  end
end

local function recharge_aircraft_carrier_power(entry)
  local power_interface = entry.power_interface
  if not (power_interface and power_interface.valid) then
    return
  end

  local current_energy = power_interface.energy or 0
  if current_energy > AIRCRAFT_CARRIER_POWER_BUFFER then
    current_energy = AIRCRAFT_CARRIER_POWER_BUFFER
  end

  local stored_energy = entry.pending_power_joules or 0
  local transferred_energy = 0
  local missing = AIRCRAFT_CARRIER_POWER_BUFFER - current_energy
  if missing > 0 then
    while stored_energy < missing do
      local fuel_inventory = get_carrier_fuel_inventory(entry)
      if not (fuel_inventory or get_ship_burner(entry.ship)) then
        break
      end
      local fuel_value = consume_one_fuel_item(entry.ship, fuel_inventory)
      if fuel_value <= 0 then
        break
      end
      stored_energy = stored_energy + fuel_value
    end
  end

  if missing > 0 and stored_energy > 0 then
    local transfer = math.min(missing, stored_energy)
    power_interface.energy = current_energy + transfer
    stored_energy = stored_energy - transfer
    transferred_energy = transfer
  end

  entry.pending_power_joules = stored_energy

  if transferred_energy > 0 then
    emit_aircraft_carrier_generation_smoke(entry)
  end
end

local function maintain_aircraft_carrier(entry)
  local ship = entry.ship
  if not (ship and ship.valid) then
    return
  end

  recharge_aircraft_carrier_power(entry)
  transfer_aircraft_carrier_cargo(entry)
  load_aircraft_carrier_roboports(entry)
end

local function is_stopped(ship)
  local s = ship.speed or 0
  return math.abs(s) < STOP_SPEED_EPS
end

local function set_battleship_artillery_auto(entry)
  local ship = entry.ship
  if not (ship and ship.valid) then return end

  local s = ship.speed or 0
  local abs_s = math.abs(s)

  -- Hysteresis: if we already consider it stopped, require higher speed to leave stopped mode.
  local moving_now
  if entry.last_stopped == true then
    moving_now = abs_s >= MOVE_SPEED_EPS
  else
    moving_now = abs_s >= STOP_SPEED_EPS
  end

  -- Debounce: require stable movement state for several ticks before switching.
  entry.stopped_ticks = entry.stopped_ticks or 0
  entry.moving_ticks = entry.moving_ticks or 0

  if moving_now then
    entry.moving_ticks = entry.moving_ticks + 1
    entry.stopped_ticks = 0
  else
    entry.stopped_ticks = entry.stopped_ticks + 1
    entry.moving_ticks = 0
  end

  -- Decide desired mode only when stable.
  local desired
  if entry.stopped_ticks >= STOP_STABLE_TICKS then
    desired = true
  elseif entry.moving_ticks >= MOVE_STABLE_TICKS then
    desired = false
  else
    return
  end

  if entry.last_stopped ~= nil and entry.last_stopped == desired then
    return
  end
  entry.last_stopped = desired

  for _, turret in pairs(entry.turrets or {}) do
    if turret and turret.valid and turret.type == "artillery-turret" then
      turret.artillery_auto_targeting = desired
      turret.active = desired
    end
  end

  dbg("[Battleship] artillery_auto=" .. tostring(desired) ..
      " speed=" .. tostring(s) ..
      " unit=" .. tostring(ship.unit_number) ..
      " name=" .. tostring(ship.name) ..
      " stopped_ticks=" .. tostring(entry.stopped_ticks) ..
      " moving_ticks=" .. tostring(entry.moving_ticks))
end

-- FIX: this function was missing an 'end' in your file.
local function sync_battleship_turrets(entry)
  local ship = entry.ship
  if not (ship and ship.valid) then
    return
  end
  local tp = tuning_for_player(entry_owner_player(entry))

  entry.turrets = entry.turrets or {}

  -- Compute ship movement once per tick.
  entry._last_ship_x = entry._last_ship_x or ship.position.x
  entry._last_ship_y = entry._last_ship_y or ship.position.y
  entry._last_ship_orientation = entry._last_ship_orientation or ship.orientation

  local dxs = ship.position.x - entry._last_ship_x
  local dys = ship.position.y - entry._last_ship_y
  local dor = ship.orientation - entry._last_ship_orientation

  local ship_moved = (dxs*dxs + dys*dys) > 1e-6 or math.abs(dor) > 1e-6
  if ship_moved then
    entry._last_ship_x = ship.position.x
    entry._last_ship_y = ship.position.y
    entry._last_ship_orientation = ship.orientation
  end

  for index = 1, #turret_offsets do
    local turret = entry.turrets[index]
    if not (turret and turret.valid) then
      turret = create_turret(ship, turret_names[index], turret_offsets[index])
      entry.turrets[index] = turret
      if not turret then
        dbg("[Battleship] turret spawn returned nil for index=" .. index .. " name=" .. turret_names[index])
      end
    end

    if turret and turret.valid then
      local offset = rotate_offset(turret_offsets[index], ship.orientation)
      local target_x = ship.position.x + offset.x
      local target_y = ship.position.y + offset.y

      if ship_moved then
        sync_turret_position(entry, turret, target_x, target_y)
        sync_turret_direction(entry, turret, ship)
      end
      ensure_battleship_turret_visual(entry, index, ship, target_x, target_y, ship.orientation)

      if ship_moved or (not entry._last_force_sync_tick) or ((game.tick - entry._last_force_sync_tick) >= tp.force_sync_ticks) then
        turret.force = ship.force
        entry._last_force_sync_tick = game.tick
      end
    end
  end
end

local function chart_ship_area(entry)
  local ship = entry.ship
  if not (ship and ship.valid) then
    return
  end

  local tp = tuning_for_player(entry_owner_player(entry))
  if entry.last_chart_tick and (game.tick - entry.last_chart_tick) < tp.radar_chart_ticks then
    return
  end

  local range = get_radar_range(ship.name)
  if range <= 0 then
    return
  end

  local position = ship.position
  if entry.last_chart_position then
    local dx = position.x - entry.last_chart_position.x
    local dy = position.y - entry.last_chart_position.y
    if (dx * dx + dy * dy) < (tp.radar_min_move_for_rechart * tp.radar_min_move_for_rechart) then
      entry.last_chart_tick = game.tick
      return
    end
  end

  ship.force.chart(ship.surface, {
    {position.x - range, position.y - range},
    {position.x + range, position.y + range},
  })
  entry.last_chart_tick = game.tick
  entry.last_chart_position = {x = position.x, y = position.y}
end

local function clamp(value, min_value, max_value)
  return math.max(min_value, math.min(max_value, value))
end

local function normalize_offset(dx, dy, desired_distance)
  local distance = math.sqrt(dx * dx + dy * dy)
  if distance < 0.001 then
    -- Use a deterministic fallback to avoid multiplayer desync from RNG.
    return {x = desired_distance, y = 0}, desired_distance
  end
  local scale = desired_distance / distance
  return {x = dx * scale, y = dy * scale}, distance
end

local function update_patrol_follow(entry, target_entry)
  if not (entry and entry.ship and entry.ship.valid) then
    return
  end
  if not (target_entry and target_entry.ship and target_entry.ship.valid) then
    entry.guard_target_unit_number = nil
    entry.guard_offset = nil
    return
  end

  local ship = entry.ship
  local target = target_entry.ship

  local tp = tuning_for_player(player_by_index(entry.guard_player_index) or entry_owner_player(entry))
  local dx = ship.position.x - target.position.x
  local dy = ship.position.y - target.position.y
  local distance = math.sqrt(dx * dx + dy * dy)
  local guard_offset = entry.guard_offset

  if not guard_offset then
    local desired_distance = clamp(distance, tp.patrol_follow_min_distance, tp.patrol_follow_max_distance)
    guard_offset = normalize_offset(dx, dy, desired_distance)
    entry.guard_offset = guard_offset
  elseif distance > tp.patrol_follow_max_distance or distance < tp.patrol_follow_min_distance then
    local desired_distance = clamp(distance, tp.patrol_follow_min_distance, tp.patrol_follow_max_distance)
    guard_offset = normalize_offset(dx, dy, desired_distance)
    entry.guard_offset = guard_offset
  end

  local desired_position = {
    x = target.position.x + guard_offset.x,
    y = target.position.y + guard_offset.y
  }

  local move_dx = desired_position.x - ship.position.x
  local move_dy = desired_position.y - ship.position.y
  local move_distance = math.sqrt(move_dx * move_dx + move_dy * move_dy)

  if move_distance < 0.1 then
    return
  end

  local step = math.min(tp.patrol_follow_step, move_distance)
  local scale = step / move_distance
  local step_pos = {
    x = ship.position.x + move_dx * scale,
    y = ship.position.y + move_dy * scale
  }

  local safe_pos = ship.surface.find_non_colliding_position(ship.name, step_pos, 0.5, 0.1)
  ship.teleport(safe_pos or step_pos)
end

local function refill_battleship_ammo(entry)
  local ship = entry.ship
  if not (ship and ship.valid) then
    return
  end

  local tp = tuning_for_player(entry_owner_player(entry))
  local interval = math.max(1, math.floor(tp.battleship_ammo_refill_ticks or DEFAULT_BATTLESHIP_AMMO_REFILL_TICKS))
  entry._last_ammo_refill_tick = entry._last_ammo_refill_tick or 0
  if (game.tick - entry._last_ammo_refill_tick) < interval then
    return
  end
  entry._last_ammo_refill_tick = game.tick

  local cargo_inventory
  if ship.type == "car" then
    cargo_inventory = ship.get_inventory(defines.inventory.car_trunk)
  else
    cargo_inventory = ship.get_inventory(defines.inventory.cargo_wagon)
  end

  if not cargo_inventory or cargo_inventory.is_empty() then
    return
  end

  local ammo_candidates = {}
  local contents = cargo_inventory.get_contents()
  for name, count in pairs(contents) do
    local item_name = name
    local item_count = count
    if type(count) == "table" then
      item_name = count.name or name
      item_count = count.count or count.amount or 0
    end
    if item_name and item_count > 0 then
      table.insert(ammo_candidates, {name = item_name, count = item_count})
    end
  end

  if #ammo_candidates == 0 then
    return
  end

  for _, turret in pairs(entry.turrets or {}) do
    if turret and turret.valid then
      local ammo_inventory = turret.get_inventory(defines.inventory.artillery_turret_ammo)
      if ammo_inventory and ammo_inventory.is_empty() then
        for _, ammo in ipairs(ammo_candidates) do
          local ok, inserted = pcall(function()
            return ammo_inventory.insert{name = ammo.name, count = ammo.count}
          end)

          if ok and inserted and inserted > 0 then
            pcall(function()
              cargo_inventory.remove{name = ammo.name, count = inserted}
            end)
            break
          end
        end
      end
    end
  end
end

local function sync_patrol_turret(entry)
  local ship = entry.ship
  if not (ship and ship.valid) then
    return
  end

  local turret = entry.turret
  if not (turret and turret.valid) then
    turret = create_turret(ship, PATROL_TURRET_NAME, patrol_turret_offsets[1])
    entry.turret = turret
  end

  if turret and turret.valid then
    entry._last_patrol_ship_x = entry._last_patrol_ship_x or ship.position.x
    entry._last_patrol_ship_y = entry._last_patrol_ship_y or ship.position.y
    entry._last_patrol_ship_orientation = entry._last_patrol_ship_orientation or ship.orientation

    local dxs = ship.position.x - entry._last_patrol_ship_x
    local dys = ship.position.y - entry._last_patrol_ship_y
    local dor = ship.orientation - entry._last_patrol_ship_orientation
    local ship_moved = (dxs * dxs + dys * dys) > 1e-6 or math.abs(dor) > 1e-6
    if ship_moved then
      entry._last_patrol_ship_x = ship.position.x
      entry._last_patrol_ship_y = ship.position.y
      entry._last_patrol_ship_orientation = ship.orientation
    end

    local offset = rotate_offset(patrol_turret_offsets[1], ship.orientation)
    local target_x = ship.position.x + offset.x
    local target_y = ship.position.y + offset.y
    if ship_moved then
      sync_turret_position(entry, turret, target_x, target_y)
      sync_turret_direction(entry, turret, ship)
    end
    local tp = tuning_for_player(entry_owner_player(entry))
    if ship_moved or (not entry._last_patrol_force_sync_tick) or ((game.tick - entry._last_patrol_force_sync_tick) >= tp.force_sync_ticks) then
      turret.force = ship.force
      entry._last_patrol_force_sync_tick = game.tick
    end
    ensure_patrol_turret_visual(entry, ship, target_x, target_y, ship.orientation)
  end
end

-- FIXED: supports atomic-bomb
local function refill_patrol_ammo(entry)
  local ship = entry.ship
  if not (ship and ship.valid) then
    return
  end

  local turret = entry.turret
  if not (turret and turret.valid) then
    return
  end

  local tp = tuning_for_player(entry_owner_player(entry))
  local interval = math.max(1, math.floor(tp.patrol_ammo_refill_ticks or DEFAULT_PATROL_AMMO_REFILL_TICKS))
  entry._last_patrol_ammo_refill_tick = entry._last_patrol_ammo_refill_tick or 0
  if (game.tick - entry._last_patrol_ammo_refill_tick) < interval then
    return
  end
  entry._last_patrol_ammo_refill_tick = game.tick

  local cargo_inventory
  if ship.type == "car" then
    cargo_inventory = ship.get_inventory(defines.inventory.car_trunk)
  else
    cargo_inventory = ship.get_inventory(defines.inventory.cargo_wagon)
  end

  if not cargo_inventory or cargo_inventory.is_empty() then
    return
  end

  local ammo_inventory = turret.get_inventory(defines.inventory.turret_ammo)
  if not ammo_inventory or not ammo_inventory.is_empty() then
    return
  end

  -- 1) atomic-bomb first (max 1)
  local nuke_available = cargo_inventory.get_item_count("atomic-bomb")
  if nuke_available > 0 then
    local inserted = ammo_inventory.insert{name = "atomic-bomb", count = 1}
    if inserted > 0 then
      cargo_inventory.remove{name = "atomic-bomb", count = inserted}
      return
    end
  end

  -- 2) normal rockets
  local ammo_types = {"explosive-rocket", "rocket"}
  for _, ammo_name in ipairs(ammo_types) do
    local available = cargo_inventory.get_item_count(ammo_name)
    if available > 0 then
      local inserted = ammo_inventory.insert{name = ammo_name, count = available}
      if inserted > 0 then
        cargo_inventory.remove{name = ammo_name, count = inserted}
        return
      end
    end
  end
end

local function ensure_entry(ship)
  if not (ship and ship.valid) then
    return
  end

  ensure_globals()

  if is_battleship_name(ship.name) then
    local entry = storage.battleships[ship.unit_number]
    if not entry then
      entry = {ship = ship, turrets = {}, last_chart_tick = nil, last_stopped = nil, owner_player_index = (ship.last_user and ship.last_user.index) or nil}
      storage.battleships[ship.unit_number] = entry
      dbg("[Battleship] ensure_entry NEW battleship unit=" .. tostring(ship.unit_number) .. " name=" .. tostring(ship.name) .. " type=" .. tostring(ship.type))
    else
      entry.ship = ship
      if ship.last_user and ship.last_user.valid then entry.owner_player_index = ship.last_user.index end
    end
    sync_battleship_turrets(entry)
    chart_ship_area(entry)

  elseif is_aircraft_carrier_name(ship.name) then
    local entry = storage.aircraft_carriers[ship.unit_number]
    if not entry then
      entry = {
        ship = ship,
        roboports = {},
        landing_pad = nil,
        request_proxy = nil,
        request_proxy_position = nil,
        power_interface = nil,
        power_pole = nil,
        last_chart_tick = nil,
        owner_player_index = (ship.last_user and ship.last_user.index) or nil,
      }
      storage.aircraft_carriers[ship.unit_number] = entry
      dbg("[Battleship] ensure_entry NEW carrier unit=" .. tostring(ship.unit_number) .. " name=" .. tostring(ship.name) .. " type=" .. tostring(ship.type))
    else
      entry.ship = ship
      if ship.last_user and ship.last_user.valid then entry.owner_player_index = ship.last_user.index end
    end
    sync_aircraft_carrier_components(entry)
    chart_ship_area(entry)

  elseif is_patrol_boat_name(ship.name) then
    local entry = storage.patrol_boats[ship.unit_number]
    if not entry then
      entry = {ship = ship, turret = nil, last_chart_tick = nil, owner_player_index = (ship.last_user and ship.last_user.index) or nil}
      storage.patrol_boats[ship.unit_number] = entry
      dbg("[Battleship] ensure_entry NEW patrol unit=" .. tostring(ship.unit_number) .. " name=" .. tostring(ship.name) .. " type=" .. tostring(ship.type))
    else
      entry.ship = ship
      if ship.last_user and ship.last_user.valid then entry.owner_player_index = ship.last_user.index end
    end
    sync_patrol_turret(entry)
    chart_ship_area(entry)
  else
    return
  end
end

local function set_patrol_selection(player_index, patrol_units)
  storage.patrol_selections[player_index] = patrol_units
end

local function get_patrol_selection(player_index)
  return storage.patrol_selections[player_index] or {}
end

local function on_patrol_selected_area(event)
  if event.item ~= PATROL_PROTECT_TOOL then
    return
  end

  ensure_globals()

  local selected = {}
  for _, entity in pairs(event.entities) do
    if entity and entity.valid and is_patrol_boat_name(entity.name) then
      selected[entity.unit_number] = true
    end
  end

  set_patrol_selection(event.player_index, selected)
end

local function on_patrol_alt_selected_area(event)
  if event.item ~= PATROL_PROTECT_TOOL then
    return
  end

  ensure_globals()

  local battleship
  for _, entity in pairs(event.entities) do
    if entity and entity.valid and is_battleship_name(entity.name) then
      battleship = entity
      break
    end
  end

  if not battleship then
    return
  end

  ensure_entry(battleship)

  local selected = get_patrol_selection(event.player_index)
  local player = game.get_player(event.player_index)
  for unit_number, _ in pairs(selected) do
    local patrol_entry = storage.patrol_boats[unit_number]
    if patrol_entry and patrol_entry.ship and patrol_entry.ship.valid then
      patrol_entry.guard_target_unit_number = battleship.unit_number
      patrol_entry.guard_player_index = event.player_index
      local dx = patrol_entry.ship.position.x - battleship.position.x
      local dy = patrol_entry.ship.position.y - battleship.position.y
      local distance = math.sqrt(dx * dx + dy * dy)
      local tp = tuning_for_player(player_by_index(patrol_entry.guard_player_index) or player)
      local desired_distance = clamp(distance, tp.patrol_follow_min_distance, tp.patrol_follow_max_distance)
      patrol_entry.guard_offset = normalize_offset(dx, dy, desired_distance)
    end
  end
end

local function on_player_selected_entity_changed(event)
  ensure_globals()
  local player = game.get_player(event.player_index)
  if not (player and player.valid) then
    return
  end

  local entity = player.selected
  if entity and entity.valid and is_patrol_boat_name(entity.name) then
    set_patrol_selection(event.player_index, {[entity.unit_number] = true})
  end
end

local function get_ship_by_unit(unit_number, is_battleship)
  if not unit_number then
    return nil
  end

  local entry_table = is_battleship and storage.battleships or storage.patrol_boats
  local entry = entry_table[unit_number]
  if entry and entry.ship and entry.ship.valid then
    return entry.ship
  end

  if game.get_entity_by_unit_number then
    local entity = game.get_entity_by_unit_number(unit_number)
    if entity and entity.valid then
      if is_battleship and is_battleship_name(entity.name) then
        ensure_entry(entity)
        return entity
      end
      if (not is_battleship) and is_patrol_boat_name(entity.name) then
        ensure_entry(entity)
        return entity
      end
    end
  end

  return nil
end

local function escort_offset_for_slot(slot)
  local slots_per_ring = 6
  local ring = math.floor((slot - 1) / slots_per_ring)
  local index = (slot - 1) % slots_per_ring
  local angle_start = math.rad(45)
  local angle_end = math.rad(135)
  local angle_step = (angle_end - angle_start) / math.max(slots_per_ring - 1, 1)
  local angle = angle_start + angle_step * index
  local radius = 8 + ring * 2

  return {
    x = math.cos(angle) * radius,
    y = math.sin(angle) * radius,
  }
end

local function escort_remove_boat(boat_unit, reason, player_index)
  if not (storage.escort and storage.escort.boats) then
    return
  end

  local data = storage.escort.boats[boat_unit]
  if not data then
    return
  end

  local target_unit = data.target
  storage.escort.boats[boat_unit] = nil

  if target_unit and storage.escort.targets and storage.escort.targets[target_unit] then
    local target_entry = storage.escort.targets[target_unit]
    if target_entry.boats then
      target_entry.boats[boat_unit] = nil
      if next(target_entry.boats) == nil then
        storage.escort.targets[target_unit] = nil
      end
    end
  end

  dbg("[Battleship] escort removed boat=" .. tostring(boat_unit) .. " reason=" .. tostring(reason), player_index)
end

local function escort_remove_target(target_unit, reason, player_index)
  if not (storage.escort and storage.escort.targets) then
    return
  end

  local target_entry = storage.escort.targets[target_unit]
  if not target_entry then
    return
  end

  for boat_unit, _ in pairs(target_entry.boats or {}) do
    escort_remove_boat(boat_unit, reason, player_index)
  end

  storage.escort.targets[target_unit] = nil
end

local function escort_set_destination(boat, position)
  local ok = pcall(function()
    boat.autopilot_destination = position
  end)

  if ok then
    return true
  end

  local ok_command = pcall(function()
    boat.set_command{
      type = defines.command.go_to_location,
      destination = position,
      radius = 1,
      distraction = defines.distraction.by_enemy
    }
  end)

  return ok_command
end

local function escort_step_move(boat, position)
  local move_dx = position.x - boat.position.x
  local move_dy = position.y - boat.position.y
  local move_distance = math.sqrt(move_dx * move_dx + move_dy * move_dy)
  if move_distance < 0.08 then
    return
  end

  pcall(function()
    local angle = math.atan2(move_dy, move_dx)
    boat.orientation = (angle / (2 * math.pi) + 0.25) % 1
  end)

  -- Smaller step reduces visible teleport jumps for escort movement.
  local step = math.min(0.35, move_distance)
  local scale = step / move_distance
  local step_pos = {
    x = boat.position.x + move_dx * scale,
    y = boat.position.y + move_dy * scale
  }
  local safe_pos = boat.surface.find_non_colliding_position(boat.name, step_pos, 0.5, 0.1)
  boat.teleport(safe_pos or step_pos)
end

local function escort_visual_follow_step(boat_unit, data)
  if not data then return end
  local boat = get_ship_by_unit(boat_unit, false)
  if not (boat and boat.valid) then
    escort_remove_boat(boat_unit, "invalid boat")
    return
  end

  local target = get_ship_by_unit(data.target, true)
  if not (target and target.valid) then
    escort_remove_boat(boat_unit, "missing target")
    return
  end

  local tp = tuning_for_player(player_by_index(data.owner_player_index) or entry_owner_player({ship = boat, owner_player_index = data.owner_player_index}))
  local escort_ticks = math.max(1, math.floor(tp.escort_update_ticks or DEFAULT_ESCORT_UPDATE_TICKS))
  if escort_ticks > 1 and (game.tick % escort_ticks) == 0 then
    -- Let the heavy escort loop own this tick to avoid double-stepping.
    return
  end

  local offset = escort_offset_for_slot(data.slot or 1)
  local rotated = rotate_offset(offset, target.orientation)
  local desired = {
    x = target.position.x + rotated.x,
    y = target.position.y + rotated.y
  }

  local cached = data.cached_avoid
  if cached then
    local max_age = math.max(2, escort_ticks * 2)
    if (game.tick - (data.cached_avoid_tick or 0)) <= max_age then
      desired.x = desired.x + (cached.x or 0)
      desired.y = desired.y + (cached.y or 0)
    end
  end

  local dx = desired.x - boat.position.x
  local dy = desired.y - boat.position.y
  local dist_sq = dx * dx + dy * dy
  if dist_sq > 0.09 then
    escort_step_move(boat, desired)
    data.last_tick = game.tick
  end
end

local function battleship_display_name(ship)
  if not (ship and ship.valid) then
    return "unknown"
  end

  local ok, backer = pcall(function() return ship.backer_name end)
  if ok and backer and backer ~= "" then
    return backer
  end

  return ship.name or "battleship"
end

local function assign_escort(player_index, battleship)
  ensure_globals()

  local selected = get_patrol_selection(player_index)
  local boat_units = {}
  for unit_number, _ in pairs(selected) do
    table.insert(boat_units, unit_number)
  end
  table.sort(boat_units)

  if #boat_units == 0 then
    return
  end

  ensure_entry(battleship)

  storage.escort.targets[battleship.unit_number] = storage.escort.targets[battleship.unit_number] or {boats = {}}

  local slot = 1
  local assigned = 0
  for _, boat_unit in ipairs(boat_units) do
    local boat = get_ship_by_unit(boat_unit, false)
    if boat and boat.valid then
      local previous = storage.escort.boats[boat_unit]
      if previous and previous.target and previous.target ~= battleship.unit_number then
        escort_remove_boat(boat_unit, "reassigned", player_index)
      end

      storage.escort.boats[boat_unit] = {
        target = battleship.unit_number,
        slot = slot,
        last_tick = game.tick,
        owner_player_index = player_index,
      }
      storage.escort.targets[battleship.unit_number].boats[boat_unit] = true
      local patrol_entry = storage.patrol_boats[boat_unit]
      if patrol_entry then
        patrol_entry.guard_target_unit_number = nil
        patrol_entry.guard_offset = nil
      end
      dbg("[Battleship] escort assigned boat=" .. tostring(boat_unit) .. " target=" .. tostring(battleship.unit_number), player_index)
      slot = slot + 1
      assigned = assigned + 1
    else
      escort_remove_boat(boat_unit, "missing boat", player_index)
    end
  end

  if assigned > 0 then
    local player = game.get_player(player_index)
    if player and player.valid then
      player.print("patrol boats (" .. tostring(assigned) .. ") will escort Battleship " .. battleship_display_name(battleship))
    end
  end
end

local function on_escort_click(event)
  if not (event and event.player_index) then
    return
  end

  local player = game.get_player(event.player_index)
  if not (player and player.valid) then
    return
  end

  local entity = player.selected
  if not (entity and entity.valid and is_battleship_name(entity.name)) then
    return
  end

  assign_escort(event.player_index, entity)
end

local function remove_ship(ship)
  if not ship then
    return
  end

  ensure_globals()

  local entry = storage.battleships[ship.unit_number]
  if entry then
    destroy_turrets(entry)
    storage.battleships[ship.unit_number] = nil
    escort_remove_target(ship.unit_number, "destroyed battleship")
  end

  local carrier_entry = storage.aircraft_carriers[ship.unit_number]
  if carrier_entry then
    destroy_aircraft_carrier_components(carrier_entry, true)
    storage.aircraft_carriers[ship.unit_number] = nil
  end

  local patrol_entry = storage.patrol_boats[ship.unit_number]
  if patrol_entry then
    destroy_patrol_turret(patrol_entry)
    storage.patrol_boats[ship.unit_number] = nil
    escort_remove_boat(ship.unit_number, "destroyed patrol boat")
  end
end

on_visual_tick = function()
  ensure_globals()

  if storage.battleships then
    for unit_number, entry in pairs(storage.battleships) do
      if not (entry.ship and entry.ship.valid) then
        destroy_turrets(entry)
        storage.battleships[unit_number] = nil
      else
        sync_battleship_turrets(entry)
      end
    end
  end

  if storage.aircraft_carriers then
    for unit_number, entry in pairs(storage.aircraft_carriers) do
      if not (entry.ship and entry.ship.valid) then
        destroy_aircraft_carrier_components(entry, false)
        storage.aircraft_carriers[unit_number] = nil
      else
        sync_aircraft_carrier_components(entry)
      end
    end
  end

  if storage.patrol_boats then
    for unit_number, entry in pairs(storage.patrol_boats) do
      if not (entry.ship and entry.ship.valid) then
        destroy_patrol_turret(entry)
        storage.patrol_boats[unit_number] = nil
      else
        sync_patrol_turret(entry)
      end
    end
  end

  if storage.escort and storage.escort.boats then
    for boat_unit, data in pairs(storage.escort.boats) do
      escort_visual_follow_step(boat_unit, data)
    end
  end
end

local function on_nth_tick()
  ensure_globals()

  if process_pending_rescans then
    process_pending_rescans()
  end

  -- Fallback scan
  if (game.tick % FALLBACK_SCAN_TICKS) == 0 then
    fallback_scan_step()
  end

  if storage.battleships then
    for unit_number, entry in pairs(storage.battleships) do
      if not (entry.ship and entry.ship.valid) then
        destroy_turrets(entry)
        storage.battleships[unit_number] = nil
      else
        set_battleship_artillery_auto(entry)
        refill_battleship_ammo(entry)
        chart_ship_area(entry)
      end
    end
  end

  if storage.aircraft_carriers then
    for unit_number, entry in pairs(storage.aircraft_carriers) do
      if not (entry.ship and entry.ship.valid) then
        destroy_aircraft_carrier_components(entry, false)
        storage.aircraft_carriers[unit_number] = nil
      else
        maintain_aircraft_carrier(entry)
        chart_ship_area(entry)
      end
    end
  end

  if storage.patrol_boats then
    for unit_number, entry in pairs(storage.patrol_boats) do
      if not (entry.ship and entry.ship.valid) then
        destroy_patrol_turret(entry)
        storage.patrol_boats[unit_number] = nil
      else
        if entry.guard_target_unit_number then
          local target_entry = storage.battleships[entry.guard_target_unit_number]
          update_patrol_follow(entry, target_entry)
        end
        refill_patrol_ammo(entry)
        chart_ship_area(entry)
      end
    end
  end

  if storage.escort and storage.escort.boats then
    for boat_unit, data in pairs(storage.escort.boats) do
      local boat = get_ship_by_unit(boat_unit, false)
      local tp = tuning_for_player(player_by_index(data.owner_player_index) or entry_owner_player({ship = boat, owner_player_index = data.owner_player_index}))
      local escort_ticks = math.max(1, math.floor(tp.escort_update_ticks or DEFAULT_ESCORT_UPDATE_TICKS))
      if (game.tick % escort_ticks) ~= 0 then
        goto continue_escort
      end
      if not (boat and boat.valid) then
        escort_remove_boat(boat_unit, "invalid boat")
      else
        local target = get_ship_by_unit(data.target, true)
        if not (target and target.valid) then
          escort_remove_boat(boat_unit, "missing target")
        else
          local offset = escort_offset_for_slot(data.slot or 1)
          local rotated = rotate_offset(offset, target.orientation)
          local desired = {
            x = target.position.x + rotated.x,
            y = target.position.y + rotated.y
          }
          local avoid = {x = 0, y = 0}
          local target_entry = storage.escort.targets and storage.escort.targets[data.target]
          if target_entry and target_entry.boats then
            for other_unit, _ in pairs(target_entry.boats) do
              if other_unit ~= boat_unit then
                local other = get_ship_by_unit(other_unit, false)
                if other and other.valid then
                  local sep_dx = boat.position.x - other.position.x
                  local sep_dy = boat.position.y - other.position.y
                  local sep_dist_sq = sep_dx * sep_dx + sep_dy * sep_dy
                  local min_sep_sq = tp.escort_min_separation_tiles * tp.escort_min_separation_tiles
                  if sep_dist_sq > 0 and sep_dist_sq < min_sep_sq then
                    local sep_dist = math.sqrt(sep_dist_sq)
                    local push = (tp.escort_min_separation_tiles - sep_dist) / tp.escort_min_separation_tiles
                    avoid.x = avoid.x + (sep_dx / sep_dist) * push
                    avoid.y = avoid.y + (sep_dy / sep_dist) * push
                  end
                end
              end
            end
          end
	          if avoid.x ~= 0 or avoid.y ~= 0 then
	            desired.x = desired.x + avoid.x * tp.escort_avoid_strength
	            desired.y = desired.y + avoid.y * tp.escort_avoid_strength
	          end
              data.cached_avoid = {
                x = avoid.x * tp.escort_avoid_strength,
                y = avoid.y * tp.escort_avoid_strength
              }
              data.cached_avoid_tick = game.tick

	          local dx = desired.x - boat.position.x
          local dy = desired.y - boat.position.y
          local dist_sq = dx * dx + dy * dy
          -- Movement is handled every tick by escort_visual_follow_step().
          -- Keep this loop for heavier calculations (avoidance / refresh cadence).
          if dist_sq > 0.5 then
            data.last_tick = game.tick
          end
        end
      end
      ::continue_escort::
    end
  end
end

queue_conversion_rescans = function(surface_index, position)
  if not (surface_index and position) then
    return
  end
  ensure_globals()
  for _, delay in ipairs(CONVERSION_RESCAN_DELAYS) do
    storage.pending_rescans[#storage.pending_rescans + 1] = {
      due_tick = game.tick + delay,
      surface_index = surface_index,
      position = {x = position.x, y = position.y},
    }
  end
end

process_pending_rescans = function()
  if not (storage.pending_rescans and #storage.pending_rescans > 0) then
    return
  end

  local keep = {}
  for i = 1, #storage.pending_rescans do
    local job = storage.pending_rescans[i]
    if job and job.due_tick and game.tick >= job.due_tick then
      local surface = game.surfaces[job.surface_index]
      if surface and surface.valid then
        local area = {
          {job.position.x - CONVERSION_RESCAN_RADIUS, job.position.y - CONVERSION_RESCAN_RADIUS},
          {job.position.x + CONVERSION_RESCAN_RADIUS, job.position.y + CONVERSION_RESCAN_RADIUS},
        }
        local ships = surface.find_entities_filtered{
          area = area,
          name = {
            BATTLESHIP_NAME,
            INDEP_BATTLESHIP_NAME,
            AIRCRAFT_CARRIER_NAME,
            INDEP_AIRCRAFT_CARRIER_NAME,
            PATROL_BOAT_NAME,
            INDEP_PATROL_BOAT_NAME
          }
        }
        for _, ship in pairs(ships) do
          ensure_entry(ship)
        end
      end
    else
      keep[#keep + 1] = job
    end
  end
  storage.pending_rescans = keep
end

local function on_built(event)
  dbg("[Battleship] on_built fired", event.player_index)
  local entity = event.entity or event.destination
  if entity and entity.valid then
    dbg("[Battleship] built entity name=" .. tostring(entity.name) .. " type=" .. tostring(entity.type), event.player_index)
  end
  if entity and entity.valid and is_ship_name(entity.name) then
    ensure_entry(entity)
    queue_conversion_rescans(entity.surface.index, entity.position)
  end
end

local function on_removed(event)
  local entity = event.entity
  if entity and entity.valid and is_ship_name(entity.name) then
    remove_ship(entity)
  end
end

local function on_runtime_mod_setting_changed(event)
  local setting = event and event.setting
  if not setting then
    invalidate_tuning_cache()
    return
  end
  if string.find(setting, "battleship", 1, true) or string.find(setting, "patrol-boat", 1, true) then
    invalidate_tuning_cache()
  end
end

local function scan_surface(surface, do_fallback)
  if not (surface and surface.valid) then
    return 0, 0
  end
  local found = 0
  local accepted = 0

  -- Fast path: exact names
  local ships_exact = surface.find_entities_filtered{
    name = {
      BATTLESHIP_NAME,
      INDEP_BATTLESHIP_NAME,
      AIRCRAFT_CARRIER_NAME,
      INDEP_AIRCRAFT_CARRIER_NAME,
      PATROL_BOAT_NAME,
      INDEP_PATROL_BOAT_NAME
    }
  }
  for _, ship in pairs(ships_exact) do
    found = found + 1
    ensure_entry(ship)
    accepted = accepted + 1
  end

  if do_fallback then
    -- Fallback path
    local candidates = surface.find_entities_filtered{type = {"cargo-wagon", "car", "locomotive"}}
    for _, e in pairs(candidates) do
      if e and e.valid and is_ship_name(e.name) then
        found = found + 1
        ensure_entry(e)
        accepted = accepted + 1
      end
    end
  end

  return found, accepted
end

fallback_scan_step = function()
  ensure_globals()
  if not (game and game.surfaces) then
    return
  end

  storage.scan_state = storage.scan_state or {surface_index = 1, deep_counter = 0}
  local surfaces = game.surfaces
  local surface_count = #surfaces
  if surface_count == 0 then
    return
  end

  local index = storage.scan_state.surface_index or 1
  if index > surface_count then
    index = 1
  end

  storage.scan_state.surface_index = index + 1
  storage.scan_state.deep_counter = (storage.scan_state.deep_counter or 0) + 1
  local do_fallback = storage.scan_state.deep_counter >= 5
  if do_fallback then
    storage.scan_state.deep_counter = 0
  end

  local surface = surfaces[index]
  if not (surface and surface.valid) then
    dbg("[Battleship] fallback scan surface invalid at index=" .. tostring(index))
    return
  end
  local found, accepted = scan_surface(surface, do_fallback)
  dbg("[Battleship] fallback scan surface=" .. tostring(surface.name) .. " found=" .. tostring(found) .. " ensured=" .. tostring(accepted))
end

init_existing = function()
  ensure_globals()
  local found = 0
  local accepted = 0

  for _, surface in pairs(game.surfaces) do
    local surface_found, surface_accepted = scan_surface(surface, true)
    found = found + surface_found
    accepted = accepted + surface_accepted
  end

  dbg("[Battleship] init_existing scan done found=" .. tostring(found) .. " ensured=" .. tostring(accepted))
end

local function init_events()
  script.on_event(defines.events.on_built_entity, on_built)
  script.on_event(defines.events.on_robot_built_entity, on_built)
  script.on_event(defines.events.script_raised_built, on_built)
  script.on_event(defines.events.script_raised_revive, on_built)
  script.on_event(defines.events.on_entity_died, on_removed)
  script.on_event(defines.events.on_player_mined_entity, on_removed)
  script.on_event(defines.events.on_robot_mined_entity, on_removed)
  script.on_event(defines.events.script_raised_destroy, on_removed)
  script.on_event(defines.events.on_player_selected_area, on_patrol_selected_area)
  script.on_event(defines.events.on_player_alt_selected_area, on_patrol_alt_selected_area)
  script.on_event(defines.events.on_runtime_mod_setting_changed, on_runtime_mod_setting_changed)
  if type(defines.events.on_player_selected_entity_changed) == "number" then
    script.on_event(defines.events.on_player_selected_entity_changed, on_player_selected_entity_changed)
  end
  script.on_event(ESCORT_CLICK_INPUT, on_escort_click)
  script.on_nth_tick(VISUAL_SYNC_NTH_TICK, on_visual_tick)
  script.on_nth_tick(BATTLESHIP_NTH_TICK, on_nth_tick)
  dbg("[Battleship] init_events hooked")
end

script.on_init(function()
  dbg("[Battleship] on_init")
  ensure_globals()
  register_ships()
  init_existing()
  init_events()
end)

script.on_configuration_changed(function()
  dbg("[Battleship] on_configuration_changed")
  ensure_globals()
  register_ships()
  init_existing()
  init_events()
end)

script.on_load(function()
  dbg("[Battleship] on_load")
  init_events()
  -- schedule scan on the next tick after loading a save
  script.on_nth_tick(1, post_load_init)
end)
