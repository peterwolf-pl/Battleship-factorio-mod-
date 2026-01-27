-- Debug helper
-- Controlled by mod settings:
-- - runtime-per-user:  battleship-debug
-- - runtime-global:    battleship-debug-global
-- If settings are missing, debug defaults to false.

local function _setting_exists_player(player, name)
  if not (player and player.valid) then return false end
  local ok, s = pcall(function() return settings.get_player_settings(player)[name] end)
  return ok and s ~= nil
end

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

  -- Per user
  if _setting_exists_player(player, "battleship-debug") then
    return settings.get_player_settings(player)["battleship-debug"].value == true
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

local BATTLESHIP_NTH_TICK = 2
local BATTLESHIP_NAME = "battleship"
local INDEP_BATTLESHIP_NAME = "indep-battleship"
local PATROL_BOAT_NAME = "patrol-boat"
local INDEP_PATROL_BOAT_NAME = "indep-patrol-boat"
local PATROL_TURRET_NAME = "patrol-boat-missile-turret"
local PATROL_PROTECT_TOOL = "patrol-boat-protect-tool"
local ESCORT_CLICK_INPUT = "battleship-escort-click"

local PATROL_FOLLOW_MIN_DISTANCE = 10
local PATROL_FOLLOW_MAX_DISTANCE = 30
local PATROL_FOLLOW_STEP = 0.6

local ESCORT_UPDATE_TICKS = 5

local RADAR_CHART_TICKS = 60

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

local function is_ship_name(name)
  return is_battleship_name(name) or is_patrol_boat_name(name)
end

-- How often we do an expensive fallback scan for ships that were created without build events.
local FALLBACK_SCAN_TICKS = 300 -- every 5 seconds

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

local function rotate_offset(offset, orientation)
  local angle = orientation * 2 * math.pi
  local cos_angle = math.cos(angle)
  local sin_angle = math.sin(angle)
  return {
    x = offset.x * cos_angle - offset.y * sin_angle,
    y = offset.x * sin_angle + offset.y * cos_angle,
  }
end

local function get_radar_range(ship_name)
  if is_battleship_name(ship_name) then
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
  storage.patrol_boats = storage.patrol_boats or {}
  storage.patrol_selections = storage.patrol_selections or {}
  storage.escort = storage.escort or {boats = {}, targets = {}}
end

local function register_ships()
  if remote.interfaces["cargo-ships"] and remote.interfaces["cargo-ships"].add_ship then
    remote.call("cargo-ships", "add_ship", {
      name = BATTLESHIP_NAME,
      engine = "cargo_ship_engine",
      engine_scale = 1,
      engine_at_front = false,
    })
    -- Independent battleship: do NOT tie it to a rail ship variant.
    -- If `rail_version` is set, cargo-ships may enforce placement on ship-rails.
    remote.call("cargo-ships", "add_boat", {
      name = INDEP_BATTLESHIP_NAME,
    })
    remote.call("cargo-ships", "add_ship", {
      name = PATROL_BOAT_NAME,
      engine = "boat_engine",
      engine_scale = 0.3,
      engine_at_front = true,
    })
    remote.call("cargo-ships", "add_boat", {
      name = INDEP_PATROL_BOAT_NAME,
      rail_version = PATROL_BOAT_NAME,
    })
  end
end

local init_existing
local is_stopped

-- Post-load initialization: on_load cannot safely use game state for scanning.
-- We schedule a one-time scan on the next tick after a save is loaded.
local function post_load_init()
  ensure_globals()
  init_existing()
  dbg("[Battleship] post_load_init finished")
  -- run once
  script.on_nth_tick(1, nil)
end

local function create_turret(ship, turret_name, offset)
  local function snap05(v)
    return math.floor(v * 2 + 0.5) / 2
  end

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
  if entry and entry.turrets then
    for _, turret in pairs(entry.turrets) do
      if turret and turret.valid then
        turret.destroy()
      end
    end
  end
end

is_stopped = function(ship)
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

local function sync_battleship_turrets(entry)
  local ship = entry.ship
  if not (ship and ship.valid) then
    return
  end

  entry.turrets = entry.turrets or {}

  -- Compute ship movement once per tick.
  -- IMPORTANT: if we update _last_ship_* inside the first turret, the rest would not move.
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
      local function snap05(v)
        return math.floor(v * 2 + 0.5) / 2
      end

      local offset = rotate_offset(turret_offsets[index], ship.orientation)
      local target_x = snap05(ship.position.x + offset.x)
      local target_y = snap05(ship.position.y + offset.y)

      -- Avoid teleporting every update tick - it can reset artillery targeting.
      -- Only move turrets when the ship actually moved or rotated.
      if ship_moved then
        local tp = turret.position
        local dxt = target_x - tp.x
        local dyt = target_y - tp.y
        if (dxt*dxt + dyt*dyt) > 1e-6 then
          turret.teleport({target_x, target_y})
        end
      end

      turret.force = ship.force
    end
  end
end

local function chart_ship_area(entry)
  local ship = entry.ship
  if not (ship and ship.valid) then
    return
  end

  if entry.last_chart_tick and (game.tick - entry.last_chart_tick) < RADAR_CHART_TICKS then
    return
  end

  local range = get_radar_range(ship.name)
  if range <= 0 then
    return
  end

  local position = ship.position
  ship.force.chart(ship.surface, {
    {position.x - range, position.y - range},
    {position.x + range, position.y + range},
  })
  entry.last_chart_tick = game.tick
end

local function clamp(value, min_value, max_value)
  return math.max(min_value, math.min(max_value, value))
end

local function normalize_offset(dx, dy, desired_distance)
  local distance = math.sqrt(dx * dx + dy * dy)
  if distance < 0.001 then
    local angle = math.random() * 2 * math.pi
    return {x = math.cos(angle) * desired_distance, y = math.sin(angle) * desired_distance}, desired_distance
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

  local dx = ship.position.x - target.position.x
  local dy = ship.position.y - target.position.y
  local distance = math.sqrt(dx * dx + dy * dy)
  local guard_offset = entry.guard_offset

  if not guard_offset then
    local desired_distance = clamp(distance, PATROL_FOLLOW_MIN_DISTANCE, PATROL_FOLLOW_MAX_DISTANCE)
    guard_offset = normalize_offset(dx, dy, desired_distance)
    entry.guard_offset = guard_offset
  elseif distance > PATROL_FOLLOW_MAX_DISTANCE or distance < PATROL_FOLLOW_MIN_DISTANCE then
    local desired_distance = clamp(distance, PATROL_FOLLOW_MIN_DISTANCE, PATROL_FOLLOW_MAX_DISTANCE)
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

  local step = math.min(PATROL_FOLLOW_STEP, move_distance)
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
      local proto = game.item_prototypes[item_name]
      if proto and proto.type == "ammo" and proto.ammo_type and proto.ammo_type.category == "artillery-shell" then
        table.insert(ammo_candidates, {name = item_name, count = item_count})
      end
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
    local offset = rotate_offset(patrol_turret_offsets[1], ship.orientation)
    turret.teleport({ship.position.x + offset.x, ship.position.y + offset.y})
    turret.force = ship.force
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
      entry = {ship = ship, turrets = {}, last_chart_tick = nil, last_stopped = nil}
      storage.battleships[ship.unit_number] = entry
      dbg("[Battleship] ensure_entry NEW battleship unit=" .. tostring(ship.unit_number) .. " name=" .. tostring(ship.name) .. " type=" .. tostring(ship.type))
    else
      entry.ship = ship
    end
    sync_battleship_turrets(entry)
    chart_ship_area(entry)

  elseif is_patrol_boat_name(ship.name) then
    local entry = storage.patrol_boats[ship.unit_number]
    if not entry then
      entry = {ship = ship, turret = nil, last_chart_tick = nil}
      storage.patrol_boats[ship.unit_number] = entry
      dbg("[Battleship] ensure_entry NEW patrol unit=" .. tostring(ship.unit_number) .. " name=" .. tostring(ship.name) .. " type=" .. tostring(ship.type))
    else
      entry.ship = ship
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
  for unit_number, _ in pairs(selected) do
    local patrol_entry = storage.patrol_boats[unit_number]
    if patrol_entry and patrol_entry.ship and patrol_entry.ship.valid then
      patrol_entry.guard_target_unit_number = battleship.unit_number
      local dx = patrol_entry.ship.position.x - battleship.position.x
      local dy = patrol_entry.ship.position.y - battleship.position.y
      local distance = math.sqrt(dx * dx + dy * dy)
      local desired_distance = clamp(distance, PATROL_FOLLOW_MIN_DISTANCE, PATROL_FOLLOW_MAX_DISTANCE)
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
  if move_distance < 0.3 then
    return
  end

  pcall(function()
    local angle = math.atan2(move_dy, move_dx)
    boat.orientation = (angle / (2 * math.pi) + 0.25) % 1
  end)

  local step = math.min(1.2, move_distance)
  local scale = step / move_distance
  local step_pos = {
    x = boat.position.x + move_dx * scale,
    y = boat.position.y + move_dy * scale
  }
  local safe_pos = boat.surface.find_non_colliding_position(boat.name, step_pos, 0.5, 0.1)
  boat.teleport(safe_pos or step_pos)
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

local function on_player_clicked(event)
  if not (event and event.button == defines.mouse_button_type.right) then
    return
  end

  local entity = event.entity
  if not (entity and entity.valid and is_battleship_name(entity.name)) then
    return
  end

  assign_escort(event.player_index, entity)
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

  local patrol_entry = storage.patrol_boats[ship.unit_number]
  if patrol_entry then
    if patrol_entry.turret and patrol_entry.turret.valid then
      patrol_entry.turret.destroy()
    end
    storage.patrol_boats[ship.unit_number] = nil
    escort_remove_boat(ship.unit_number, "destroyed patrol boat")
  end
end

local function on_nth_tick()
  ensure_globals()

  -- Fallback scan: cargo-ships/pelagos may create/replace ships via script without build events.
  -- Scan once per second to attach turrets to any missing ships.
  if (game.tick % FALLBACK_SCAN_TICKS) == 0 then
    init_existing()
  end

  if storage.battleships then
    for unit_number, entry in pairs(storage.battleships) do
      if not (entry.ship and entry.ship.valid) then
        destroy_turrets(entry)
        storage.battleships[unit_number] = nil
      else
        sync_battleship_turrets(entry)
        set_battleship_artillery_auto(entry)
        refill_battleship_ammo(entry)
        chart_ship_area(entry)
      end
    end
  end

  if storage.patrol_boats then
    for unit_number, entry in pairs(storage.patrol_boats) do
      if not (entry.ship and entry.ship.valid) then
        if entry.turret and entry.turret.valid then
          entry.turret.destroy()
        end
        storage.patrol_boats[unit_number] = nil
      else
        if entry.guard_target_unit_number then
          local target_entry = storage.battleships[entry.guard_target_unit_number]
          update_patrol_follow(entry, target_entry)
        end
        sync_patrol_turret(entry)
        refill_patrol_ammo(entry)
        chart_ship_area(entry)
      end
    end
  end

  if storage.escort and storage.escort.boats and (game.tick % ESCORT_UPDATE_TICKS) == 0 then
    for boat_unit, data in pairs(storage.escort.boats) do
      local boat = get_ship_by_unit(boat_unit, false)
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

          local dx = desired.x - boat.position.x
          local dy = desired.y - boat.position.y
          local dist_sq = dx * dx + dy * dy
          if dist_sq > 0.5 then
            local moved = escort_set_destination(boat, desired)
            if not moved then
              escort_step_move(boat, desired)
            end
            data.last_tick = game.tick
          end
        end
      end
    end
  end
end

local function on_built(event)
  dbg("[Battleship] on_built fired", event.player_index)
  local entity = event.entity or event.destination
  if entity and entity.valid then
    dbg("[Battleship] built entity name=" .. tostring(entity.name) .. " type=" .. tostring(entity.type), event.player_index)
  end
  if entity and entity.valid and is_ship_name(entity.name) then
    ensure_entry(entity)
  end
end

local function on_removed(event)
  local entity = event.entity
  if entity and entity.valid and is_ship_name(entity.name) then
    remove_ship(entity)
  end
end

init_existing = function()
  ensure_globals()
  local found = 0
  local accepted = 0

  for _, surface in pairs(game.surfaces) do
    -- Fast path: exact names
    local ships_exact = surface.find_entities_filtered{name = {BATTLESHIP_NAME, INDEP_BATTLESHIP_NAME, PATROL_BOAT_NAME, INDEP_PATROL_BOAT_NAME}}
    for _, ship in pairs(ships_exact) do
      found = found + 1
      ensure_entry(ship)
      accepted = accepted + 1
    end

    -- Fallback path: scan common rolling-stock types and accept by substring.
    -- This catches cases where another mod renames the rolling stock prototypes.
    local candidates = surface.find_entities_filtered{type = {"cargo-wagon", "car", "locomotive"}}
    for _, e in pairs(candidates) do
      if e and e.valid and is_ship_name(e.name) then
        found = found + 1
        ensure_entry(e)
        accepted = accepted + 1
      end
    end
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
  if type(defines.events.on_player_selected_entity_changed) == "number" then
    script.on_event(defines.events.on_player_selected_entity_changed, on_player_selected_entity_changed)
  end
  script.on_event(ESCORT_CLICK_INPUT, on_escort_click)
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
