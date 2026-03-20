local battleship_icons = {
  {
    icon = GRAPHICSPATH .. "icons/cargoship_icon.png",
    icon_size = 64,
    tint = {0.75, 0.95, 0.75}
  },
  {
    icon = "__base__/graphics/icons/artillery-turret.png",
    icon_size = 64,
    scale = 0.5,
    shift = {8, 8}
  }
}

local patrol_boat_icons = {
  {
    icon = GRAPHICSPATH .. "icons/boat.png",
    icon_size = 64,
    tint = {0.7, 0.9, 0.7}
  },
  {
    icon = "__base__/graphics/icons/rocket-launcher.png",
    icon_size = 64,
    scale = 0.5,
    shift = {8, 8}
  }
}

local aircraft_carrier_icons = {
  {
    icon = GRAPHICSPATH .. "icons/cargoship_icon.png",
    icon_size = 64,
    tint = {0.75, 0.9, 1}
  },
  {
    icon = "__base__/graphics/icons/roboport.png",
    icon_size = 64,
    scale = 0.5,
    shift = {8, 6}
  },
  {
    icon = "__long_range_delivery_drones_peterwolf_fork__/data/long-range-delivery-drone/request-depot-icon.png",
    icon_size = 64,
    scale = 0.28,
    shift = {-9, 10}
  }
}

local cargo_ship = data.raw["cargo-wagon"]["cargo_ship"]
local boat = data.raw["cargo-wagon"]["boat"]
local request_depot_base = data.raw["logistic-container"]["long-range-delivery-drone-request-depot"]
local roboport_base = data.raw["roboport"]["roboport"]
local power_pole_base = data.raw["electric-pole"]["substation"]
local battleship_speed_multiplier = settings.startup["battleship-speed-multiplier"].value
local patrol_boat_speed_multiplier = settings.startup["patrol-boat-speed-multiplier"].value
local patrol_boat_missile_range_multiplier = settings.startup["patrol-boat-missile-range-multiplier"].value


-- ---------------------------------------------------------------------------
-- Make the Patrol Boat missile turret fully invisible (graphics only).
-- Keep ALL shooting logic untouched; we only strip renderable pictures/animations.
-- This is required because the turret entity is created/respawned at runtime.
-- ---------------------------------------------------------------------------
local function make_empty_rotated_animation()
  return {
    filename = "__core__/graphics/empty.png",
    width = 1,
    height = 1,
    frame_count = 1,
    direction_count = 1,
    line_length = 1,
    animation_speed = 1
  }
end

local function make_empty_rotated_sprite()
  return {
    filename = "__core__/graphics/empty.png",
    width = 1,
    height = 1,
    direction_count = 1
  }
end

local function make_empty_animation()
  return {
    filename = "__core__/graphics/empty.png",
    width = 1,
    height = 1,
    frame_count = 1,
    line_length = 1,
    animation_speed = 1
  }
end

local function make_empty_layers()
  return {
    layers = {
      {
        filename = "__core__/graphics/empty.png",
        width = 1,
        height = 1,
        frame_count = 1
      }
    }
  }
end

local function make_shifted_sprite(sprite, dx, dy, scale_multiplier)
  if not sprite then return nil end

  local shifted = table.deepcopy(sprite)
  local shift = shifted.shift or {0, 0}
  local sx = shift.x or shift[1] or 0
  local sy = shift.y or shift[2] or 0
  shifted.shift = {sx + (dx or 0), sy + (dy or 0)}

  if shifted.scale and scale_multiplier then
    shifted.scale = shifted.scale * scale_multiplier
  end

  shifted.draw_as_shadow = nil
  return shifted
end

local function strip_turret_graphics(turret)
  if not turret then return end
  -- Common turret fields (optional depending on base prototype)
  if turret.folded_animation ~= nil then turret.folded_animation = make_empty_rotated_animation() end
  if turret.preparing_animation ~= nil then turret.preparing_animation = make_empty_rotated_animation() end
  if turret.prepared_animation ~= nil then turret.prepared_animation = make_empty_rotated_animation() end
  if turret.attacking_animation ~= nil then turret.attacking_animation = make_empty_rotated_animation() end
  if turret.starting_attack_animation ~= nil then turret.starting_attack_animation = make_empty_rotated_animation() end
  if turret.ending_attack_animation ~= nil then turret.ending_attack_animation = make_empty_rotated_animation() end
  if turret.folding_animation ~= nil then turret.folding_animation = make_empty_rotated_animation() end

  if turret.base_picture ~= nil then turret.base_picture = make_empty_rotated_sprite() end
  if turret.base_picture_render_layer ~= nil then turret.base_picture_render_layer = "object" end
  if turret.graphics_set ~= nil then turret.graphics_set = {} end
  if turret.water_reflection ~= nil then turret.water_reflection = nil end

  -- Some turret prototypes embed animation on attack_parameters; strip if present.
  if type(turret.attack_parameters) == "table" and turret.attack_parameters.animation ~= nil then
    turret.attack_parameters.animation = nil
  end

  -- Hide from encyclopaedia/blueprints; entity can still exist and shoot.
  turret.hidden = true
  turret.hidden_in_factoriopedia = true
  turret.selectable_in_game = false
end

-- Optional custom Patrol Boat graphics (Battleship-graphics mod)
local function get_patrolboat_sprite_prefix()
  -- Try a few likely mod names, keep it defensive.
  if mods and (mods["Battleship-graphics"] or mods["Battleship_graphics"] or mods["battleship-graphics"] or mods["battleship_graphics"]) then
    local mod_name = mods["Battleship-graphics"] and "Battleship-graphics"
      or (mods["Battleship_graphics"] and "Battleship_graphics")
      or (mods["battleship-graphics"] and "battleship-graphics")
      or "battleship_graphics"
    return "__" .. mod_name .. "__/graphics/patrolboat/"
  end
  return nil
end

local function build_patrolboat_filenames(prefix)
  if not prefix then return nil end
  local t = {}
  for i = 1, 256 do
    t[#t+1] = prefix .. string.format("%04d.png", i)
  end
  return t
end


local function normalize_rotated_layers_direction_count(layers)
  if type(layers) ~= "table" then return end

  local target_direction_count = nil

  for i = 1, #layers do
    local layer = layers[i]
    if type(layer) == "table" then
      local dc = layer.direction_count
      if type(dc) == "number" and dc > 0 then
        if not target_direction_count or dc > target_direction_count then
          target_direction_count = dc
        end
      elseif type(layer.filenames) == "table" and #layer.filenames > 0 then
        if not target_direction_count or #layer.filenames > target_direction_count then
          target_direction_count = #layer.filenames
        end
      end
    end
  end

  if not target_direction_count or target_direction_count < 1 then
    target_direction_count = 1
  end

  for i = 1, #layers do
    local layer = layers[i]
    if type(layer) == "table" then
      layer.direction_count = target_direction_count

      if type(layer.filenames) == "table" and #layer.filenames > 0 then
        layer.lines_per_file = layer.lines_per_file or 1
        layer.line_length = layer.line_length or math.min(target_direction_count, #layer.filenames)
      end
    end
  end
end



local function collapse_rotated_layers_to_single_visible_layer(container)
  if type(container) ~= "table" then return end
  local rotated = container.rotated or container
  if type(rotated) ~= "table" then return end
  local layers = rotated.layers
  if type(layers) ~= "table" or #layers == 0 then return end

  local selected = nil

  for i = 1, #layers do
    local layer = layers[i]
    if type(layer) == "table" and not layer.draw_as_shadow then
      selected = table.deepcopy(layer)
      break
    end
  end

  if not selected and type(layers[1]) == "table" then
    selected = table.deepcopy(layers[1])
  end

  if not selected then return end

  local target_direction_count = nil
  if type(selected.direction_count) == "number" and selected.direction_count > 0 then
    target_direction_count = selected.direction_count
  elseif type(selected.filenames) == "table" and #selected.filenames > 0 then
    target_direction_count = #selected.filenames
  else
    target_direction_count = 1
  end

  selected.direction_count = target_direction_count
  if selected.frame_count == nil then
    selected.frame_count = 1
  end
  if selected.line_length == nil or selected.line_length < 1 then
    if type(selected.filenames) == "table" and #selected.filenames > 0 then
      selected.line_length = 1
      selected.lines_per_file = selected.lines_per_file or 1
    else
      selected.line_length = target_direction_count
    end
  end

  rotated.layers = {selected}
end

local function try_apply_patrolboat_graphics(target)
  if not target then return end
  local prefix = get_patrolboat_sprite_prefix()
  local filenames = build_patrolboat_filenames(prefix)
  if not filenames then return end

  local function make_new_sprite(old)
    if type(old) ~= "table" then return nil end
    local s = table.deepcopy(old)

    -- Switch to per-direction files (0001..0256).
    s.filename = nil
    s.filenames = filenames
    s.lines_per_file = 1
    s.line_length = 1
    s.frame_count = 1
    s.direction_count = 256

    -- Battleship-graphics patrolboat frames are 474x458.
    s.width = 474
    s.height = 458

    -- Prevent HR mismatch / missing files and remove inherited tint/mask state.
    s.hr_version = nil
    s.tint = nil
    s.apply_runtime_tint = nil
    s.blend_mode = nil
    s.opacity = nil

    -- Atlas/stripe-only fields don't apply for per-file directions.
    s.slice = nil
    s.stripes = nil

    return s
  end

  local function make_empty_visible_layer(source_layer)
    local layer = {
      filename = "__core__/graphics/empty.png",
      width = 1,
      height = 1,
      frame_count = 1,
      direction_count = 1,
      line_length = 1,
      scale = 1
    }

    if type(source_layer) == "table" then
      local preserved_frame_count = 1
      local preserved_direction_count = 1

      -- Car animation layers must keep matching animation progression values.
      -- Preserve them even on stripped overlay layers to avoid prototype load errors.
      if type(source_layer.frame_count) == "number" and source_layer.frame_count > 0 then
        preserved_frame_count = source_layer.frame_count
      end
      if type(source_layer.direction_count) == "number" and source_layer.direction_count > 0 then
        preserved_direction_count = source_layer.direction_count
      end
      layer.frame_count = preserved_frame_count
      layer.direction_count = preserved_direction_count

      -- `__core__/graphics/empty.png` is a single 64x64 sprite sheet. When we preserve
      -- high direction counts from boat overlays, a placeholder with `line_length = 1`
      -- overflows vertically at frame 65+. Pack the preserved cells into rows instead.
      local preserved_cell_count = preserved_frame_count * preserved_direction_count
      local preferred_line_length = source_layer.line_length
      if type(preferred_line_length) ~= "number" or preferred_line_length < 1 then
        preferred_line_length = preserved_cell_count
      end
      local required_line_length = math.ceil(preserved_cell_count / 64)
      layer.line_length = math.min(
        64,
        math.max(1, preferred_line_length, preserved_frame_count, required_line_length)
      )

      if source_layer.max_advance ~= nil then
        layer.max_advance = source_layer.max_advance
      end
      if source_layer.animation_speed ~= nil then
        layer.animation_speed = source_layer.animation_speed
      end
      if source_layer.repeat_count ~= nil then
        layer.repeat_count = source_layer.repeat_count
      end
      if source_layer.priority ~= nil then
        layer.priority = source_layer.priority
      end
    end

    return layer
  end

  local function normalize_rotated_layers_direction_count_local(layers)
    if type(layers) ~= "table" then return end

    local target_direction_count = nil

    for i = 1, #layers do
      local layer = layers[i]
      if type(layer) == "table" then
        local dc = layer.direction_count
        if type(dc) == "number" and dc > 0 then
          if not target_direction_count or dc > target_direction_count then
            target_direction_count = dc
          end
        elseif type(layer.filenames) == "table" and #layer.filenames > 0 then
          if not target_direction_count or #layer.filenames > target_direction_count then
            target_direction_count = #layer.filenames
          end
        end
      end
    end

    if not target_direction_count or target_direction_count < 1 then
      target_direction_count = 1
    end

    for i = 1, #layers do
      local layer = layers[i]
      if type(layer) == "table" then
        layer.direction_count = target_direction_count

        if type(layer.filenames) == "table" and #layer.filenames > 0 then
          layer.lines_per_file = layer.lines_per_file or 1
          layer.line_length = layer.line_length or math.min(target_direction_count, #layer.filenames)
        end
      end
    end
  end

  local function patch_layers(layers)
    if type(layers) ~= "table" then return end

    local visible_layer_seen = false

    for i = 1, #layers do
      local layer = layers[i]
      if type(layer) == "table" then
        if layer.draw_as_shadow then
          layer.scale = 0.4
          -- Custom patrolboat sprites are shorter than the original boat graphics,
          -- so the inherited shadow often ends up too far away. Nudge it closer.
          local adj_x, adj_y = 0, -0.5
          if type(layer.shift) == "table" and type(layer.shift[1]) == "number" and type(layer.shift[2]) == "number" then
            layer.shift = {layer.shift[1] + adj_x, layer.shift[2] + adj_y}
          else
            layer.shift = {adj_x, adj_y}
          end
        else
          -- indep-boat can inherit multiple visible layers (base + tint/mask overlay).
          -- Replacing all of them with the same patrolboat sprite causes the doubled,
          -- semi-transparent ghost image when entering the vehicle.
          if not visible_layer_seen then
            local new_layer = make_new_sprite(layer)
            if new_layer then
              layers[i] = new_layer
              visible_layer_seen = true
            end
          else
            local empty = make_empty_visible_layer(layer)
            local preserved_shift = nil
            if type(layer.shift) == "table" then
              preserved_shift = table.deepcopy(layer.shift)
            end
            layers[i] = empty
            if preserved_shift then
              layers[i].shift = preserved_shift
            end
          end
        end
      end
    end
  end

  local function patch_container(container)
    if type(container) ~= "table" then return end

    -- Layered sprite container
    if container.layers and type(container.layers) == "table" then
      patch_layers(container.layers)
      normalize_rotated_layers_direction_count_local(container.layers)
      return
    end

    -- Direct sprite definition (no layers)
    if container.filename or container.filenames then
      local new_self = make_new_sprite(container)
      if new_self then
        for k in pairs(container) do container[k] = nil end
        for k,v in pairs(new_self) do container[k] = v end
      end
      return
    end
  end

  -- cargo-wagon variant
  if target.pictures then
    if target.pictures.rotated then
      patch_container(target.pictures.rotated)
    end
    patch_container(target.pictures)
  end

  -- car variant
  if target.animation then
    patch_container(target.animation)
  end
end

local function copy_indep_boat_graphics_to_patrol_boat(rail_boat, source_indep_boat)
  if not rail_boat or not source_indep_boat then return end

  local rotated = rail_boat.pictures and rail_boat.pictures.rotated
  local source_layers = source_indep_boat.animation and source_indep_boat.animation.layers
  if type(rotated) ~= "table" or type(source_layers) ~= "table" then return end

  local converted_layers = {}

  for _, layer in ipairs(source_layers) do
    if type(layer) == "table" then
      local converted = {
        priority = layer.priority,
        width = layer.width,
        height = layer.height,
        direction_count = layer.direction_count or 256,
        allow_low_quality_rotation = true,
        scale = layer.scale,
        shift = type(layer.shift) == "table" and table.deepcopy(layer.shift) or layer.shift,
        draw_as_shadow = layer.draw_as_shadow
      }

      if layer.filename then
        converted.filename = layer.filename
      elseif type(layer.filenames) == "table" and #layer.filenames > 0 then
        converted.filenames = table.deepcopy(layer.filenames)
        converted.line_length = layer.line_length or 1
        converted.lines_per_file = layer.lines_per_file or 1
      elseif type(layer.stripes) == "table" and #layer.stripes > 0 then
        converted.filenames = {}
        for _, stripe in ipairs(layer.stripes) do
          if type(stripe) == "table" and stripe.filename then
            converted.filenames[#converted.filenames + 1] = stripe.filename
            converted.line_length = converted.line_length or stripe.width_in_frames or 1
            converted.lines_per_file = converted.lines_per_file or stripe.height_in_frames or 1
          end
        end
      end

      if converted.filename or (type(converted.filenames) == "table" and #converted.filenames > 0) then
        converted_layers[#converted_layers + 1] = converted
      end
    end
  end

  if #converted_layers > 0 then
    normalize_rotated_layers_direction_count(converted_layers)
    rotated.layers = converted_layers
  end

  rail_boat.water_reflection = table.deepcopy(source_indep_boat.water_reflection)
end

-- Battleship - version that works on rails (cargo-wagon variant, looks like cargo_ship)
local battleship = table.deepcopy(cargo_ship)
battleship.name = "battleship"
battleship.icons = battleship_icons
battleship.icon = nil
battleship.minable = {mining_time = 2, result = "battleship"}
battleship.max_health = 7500
battleship.inventory_size = 800
battleship.placeable_by = {{item = "battleship", count = 1}}
battleship.localised_name = {"entity-name.battleship"}
battleship.localised_description = {"entity-description.battleship"}
if battleship.max_speed then
  battleship.max_speed = battleship.max_speed * battleship_speed_multiplier
end

if battleship.pictures and battleship.pictures.rotated and battleship.pictures.rotated.layers then
  battleship.pictures.rotated.layers[1].tint = {0.75, 0.95, 0.75}
end

-- Independent battleship - version that works off-rails (car base, cargo_ship appearance)
local indep_boat = data.raw["car"]["indep-boat"]
local indep_battleship = table.deepcopy(indep_boat)
indep_battleship.name = "indep-battleship"
indep_battleship.icons = battleship_icons
indep_battleship.icon = nil
indep_battleship.minable = {mining_time = 2, result = "battleship"}
indep_battleship.max_health = 7500
indep_battleship.inventory_size = 800
indep_battleship.localised_name = {"entity-name.battleship"}
indep_battleship.localised_description = {"entity-description.battleship"}
indep_battleship.placeable_by = {{item = "battleship", count = 1}}
-- Copy cargo_ship visual and physical properties
if cargo_ship.pictures and cargo_ship.pictures.rotated and cargo_ship.pictures.rotated.layers then 
  local cargo_ship_layers = table.deepcopy(cargo_ship.pictures.rotated.layers)
  if cargo_ship_layers[1] then
    cargo_ship_layers[1].tint = {0.75, 0.95, 0.75}
  end
  indep_battleship.animation = {layers = cargo_ship_layers}
  indep_battleship.pictures = nil
  indep_battleship.water_reflection = cargo_ship.water_reflection
end
-- Apply speed multiplier
if indep_battleship.max_speed then
  indep_battleship.max_speed = indep_battleship.max_speed * battleship_speed_multiplier
end

local aircraft_carrier = table.deepcopy(battleship)
aircraft_carrier.name = "aircraft-carrier"
aircraft_carrier.icons = aircraft_carrier_icons
aircraft_carrier.icon = nil
aircraft_carrier.minable = {mining_time = 2, result = "aircraft-carrier"}
aircraft_carrier.placeable_by = {{item = "aircraft-carrier", count = 1}}
aircraft_carrier.localised_name = {"entity-name.aircraft-carrier"}
aircraft_carrier.localised_description = {"entity-description.aircraft-carrier"}
if aircraft_carrier.pictures and aircraft_carrier.pictures.rotated and aircraft_carrier.pictures.rotated.layers then
  aircraft_carrier.pictures.rotated.layers[1].tint = {0.75, 0.9, 1}
end

local indep_aircraft_carrier = table.deepcopy(indep_battleship)
indep_aircraft_carrier.name = "indep-aircraft-carrier"
indep_aircraft_carrier.icons = aircraft_carrier_icons
indep_aircraft_carrier.icon = nil
indep_aircraft_carrier.minable = {mining_time = 2, result = "aircraft-carrier"}
indep_aircraft_carrier.placeable_by = {{item = "aircraft-carrier", count = 1}}
indep_aircraft_carrier.localised_name = {"entity-name.aircraft-carrier"}
indep_aircraft_carrier.localised_description = {"entity-description.aircraft-carrier"}
if indep_aircraft_carrier.animation and indep_aircraft_carrier.animation.layers and indep_aircraft_carrier.animation.layers[1] then
  indep_aircraft_carrier.animation.layers[1].tint = {0.75, 0.9, 1}
end

local artillery_base = table.deepcopy(data.raw["artillery-turret"]["artillery-turret"])
artillery_base.flags = {
  "placeable-off-grid",
  "not-on-map",
  "not-blueprintable",
  "not-deconstructable"
}
artillery_base.energy_source = {
  type = "electric",
  buffer_capacity = "1MJ",
  input_flow_limit = "1MW",
  drain = "0W",
  usage_priority = "secondary-input"
}
artillery_base.max_health = 1200
artillery_base.minable = {mining_time = 20, result = "artillery-turret"}

-- IMPORTANT: zero-sized boxes often make create_entity fail on modded water/ship tiles.
-- Use tiny boxes instead.
artillery_base.collision_box = {{-0.2, -0.2}, {0.2, 0.2}}
artillery_base.collision_mask = {layers = {}}
artillery_base.selection_box = {{-0.2, -0.2}, {0.2, 0.2}}
artillery_base.selection_priority = 0
artillery_base.order = "z[battleship-cannon]"
artillery_base.icons = battleship_icons
artillery_base.icon = nil
artillery_base.corpse = nil
artillery_base.damaged_trigger_effect = nil
-- Hide the real artillery entities (logic only); visuals are drawn at runtime via rendering API.
strip_turret_graphics(artillery_base)

local battleship_cannon_1 = table.deepcopy(artillery_base)
battleship_cannon_1.name = "battleship-cannon-1"

local battleship_cannon_2 = table.deepcopy(artillery_base)
battleship_cannon_2.name = "battleship-cannon-2"

local battleship_cannon_3 = table.deepcopy(artillery_base)
battleship_cannon_3.name = "battleship-cannon-3"

local battleship_cannon_4 = table.deepcopy(artillery_base)
battleship_cannon_4.name = "battleship-cannon-4"

-- Patrol boat - version that works on rails (cargo-wagon variant)
local boat_for_patrol = data.raw["cargo-wagon"]["boat"]
local patrol_boat = table.deepcopy(boat_for_patrol)
patrol_boat.name = "patrol-boat"
patrol_boat.icons = patrol_boat_icons
patrol_boat.icon = nil
patrol_boat.minable = {mining_time = 1, result = "patrol-boat"}
patrol_boat.placeable_by = {{item = "patrol-boat", count = 1}}
patrol_boat.max_health = 2000
patrol_boat.inventory_size = 80
patrol_boat.localised_name = {"entity-name.patrol-boat"}
patrol_boat.localised_description = {"entity-description.patrol-boat"}
if patrol_boat.max_speed then
  patrol_boat.max_speed = patrol_boat.max_speed * patrol_boat_speed_multiplier
end

copy_indep_boat_graphics_to_patrol_boat(patrol_boat, indep_boat)

try_apply_patrolboat_graphics(patrol_boat)
if patrol_boat.pictures and patrol_boat.pictures.rotated and patrol_boat.pictures.rotated.layers then
  normalize_rotated_layers_direction_count(patrol_boat.pictures.rotated.layers)
  collapse_rotated_layers_to_single_visible_layer(patrol_boat.pictures)
end

local patrol_indep_boat = data.raw["car"]["indep-boat"]
local indep_patrol_boat = table.deepcopy(patrol_indep_boat)
indep_patrol_boat.name = "indep-patrol-boat"
indep_patrol_boat.icons = patrol_boat_icons
indep_patrol_boat.icon = nil
indep_patrol_boat.minable = {mining_time = 1, result = "patrol-boat"}
indep_patrol_boat.max_health = patrol_boat.max_health
indep_patrol_boat.inventory_size = patrol_boat.inventory_size
indep_patrol_boat.localised_name = {"entity-name.patrol-boat"}
indep_patrol_boat.localised_description = {"entity-description.patrol-boat"}
if indep_patrol_boat.max_speed then
  indep_patrol_boat.max_speed = indep_patrol_boat.max_speed * patrol_boat_speed_multiplier
end

try_apply_patrolboat_graphics(indep_patrol_boat)

local missile_turret = table.deepcopy(data.raw["ammo-turret"]["gun-turret"])
local rocket_launcher = data.raw["gun"]["rocket-launcher"]
local rocket_launcher_range = rocket_launcher and rocket_launcher.attack_parameters and rocket_launcher.attack_parameters.range or 25
local rocket_launcher_cooldown = rocket_launcher and rocket_launcher.attack_parameters and rocket_launcher.attack_parameters.cooldown or missile_turret.attack_parameters.cooldown
missile_turret.name = "patrol-boat-missile-turret"
missile_turret.flags = {
  "placeable-off-grid",
  "not-on-map",
  "not-blueprintable",
  "not-deconstructable"
}
missile_turret.icons = patrol_boat_icons
missile_turret.icon = nil
missile_turret.minable = nil
missile_turret.max_health = 800

-- Same rationale: avoid 0-sized boxes.
missile_turret.collision_box = {{-0.2, -0.2}, {0.2, 0.2}}
missile_turret.collision_mask = {layers = {}}
missile_turret.selection_box = {{-0.2, -0.2}, {0.2, 0.2}}
missile_turret.selection_priority = 0
missile_turret.corpse = nil
missile_turret.damaged_trigger_effect = nil
missile_turret.order = "z[patrol-boat-missile-turret]"
missile_turret.attack_parameters.ammo_category = "rocket"
missile_turret.attack_parameters.range = rocket_launcher_range * patrol_boat_missile_range_multiplier
missile_turret.attack_parameters.cooldown = rocket_launcher_cooldown
strip_turret_graphics(missile_turret)

local aircraft_carrier_roboport = table.deepcopy(roboport_base)
aircraft_carrier_roboport.name = "aircraft-carrier-roboport"
aircraft_carrier_roboport.icons = aircraft_carrier_icons
aircraft_carrier_roboport.icon = nil
aircraft_carrier_roboport.localised_name = {"entity-name.aircraft-carrier"}
aircraft_carrier_roboport.localised_description = {"entity-description.aircraft-carrier"}
aircraft_carrier_roboport.flags = {
  "placeable-off-grid",
  "not-on-map",
  "not-blueprintable",
  "not-deconstructable"
}
aircraft_carrier_roboport.minable = nil
aircraft_carrier_roboport.max_health = 1000
aircraft_carrier_roboport.collision_box = {{-0.2, -0.2}, {0.2, 0.2}}
aircraft_carrier_roboport.collision_mask = {layers = {}}
aircraft_carrier_roboport.selection_box = {{-0.7, -0.7}, {0.7, 0.7}}
aircraft_carrier_roboport.selection_priority = 0
aircraft_carrier_roboport.corpse = nil
aircraft_carrier_roboport.damaged_trigger_effect = nil
aircraft_carrier_roboport.next_upgrade = nil
aircraft_carrier_roboport.fast_replaceable_group = nil
aircraft_carrier_roboport.base = make_empty_layers()
aircraft_carrier_roboport.base_patch = make_empty_animation()
aircraft_carrier_roboport.base_animation = make_empty_animation()
aircraft_carrier_roboport.door_animation_up = make_empty_animation()
aircraft_carrier_roboport.door_animation_down = make_empty_animation()
aircraft_carrier_roboport.recharging_animation = make_empty_animation()
aircraft_carrier_roboport.water_reflection = nil
aircraft_carrier_roboport.energy_source.buffer_capacity = "1GJ"
aircraft_carrier_roboport.energy_source.input_flow_limit = "100MW"
aircraft_carrier_roboport.charging_energy = "2500kW"
aircraft_carrier_roboport.logistics_radius = (aircraft_carrier_roboport.logistics_radius or 25) * 10
aircraft_carrier_roboport.construction_radius = (aircraft_carrier_roboport.construction_radius or 55) * 10
aircraft_carrier_roboport.logistics_connection_distance = (aircraft_carrier_roboport.logistics_connection_distance or 50) * 10
aircraft_carrier_roboport.energy_usage = aircraft_carrier_roboport.energy_usage or "100kW"
aircraft_carrier_roboport.recharge_minimum = "1MJ"
aircraft_carrier_roboport.allow_copy_paste = false

local aircraft_carrier_landing_pad = table.deepcopy(request_depot_base)
aircraft_carrier_landing_pad.name = "aircraft-carrier-landing-pad"
aircraft_carrier_landing_pad.icons = aircraft_carrier_icons
aircraft_carrier_landing_pad.icon = nil
aircraft_carrier_landing_pad.localised_name = {"entity-name.aircraft-carrier"}
aircraft_carrier_landing_pad.localised_description = {"entity-description.aircraft-carrier"}
aircraft_carrier_landing_pad.flags = {
  "placeable-off-grid",
  "not-on-map",
  "not-blueprintable",
  "not-deconstructable"
}
aircraft_carrier_landing_pad.minable = nil
aircraft_carrier_landing_pad.inventory_size = 800
aircraft_carrier_landing_pad.collision_box = {{-0.2, -0.2}, {0.2, 0.2}}
aircraft_carrier_landing_pad.collision_mask = {layers = {}}
aircraft_carrier_landing_pad.selection_box = {{-0.8, -0.8}, {0.8, 0.8}}
aircraft_carrier_landing_pad.selection_priority = 0
aircraft_carrier_landing_pad.corpse = nil
aircraft_carrier_landing_pad.damaged_trigger_effect = nil
aircraft_carrier_landing_pad.fast_replaceable_group = nil
aircraft_carrier_landing_pad.next_upgrade = nil
aircraft_carrier_landing_pad.allow_copy_paste = false
aircraft_carrier_landing_pad.animation = make_empty_layers()

local aircraft_carrier_request_proxy = table.deepcopy(request_depot_base)
aircraft_carrier_request_proxy.name = "aircraft-carrier-request-proxy"
aircraft_carrier_request_proxy.icons = aircraft_carrier_icons
aircraft_carrier_request_proxy.icon = nil
aircraft_carrier_request_proxy.localised_name = {"entity-name.aircraft-carrier"}
aircraft_carrier_request_proxy.localised_description = {"entity-description.aircraft-carrier"}
aircraft_carrier_request_proxy.flags = {
  "placeable-off-grid",
  "not-on-map",
  "not-blueprintable",
  "not-deconstructable"
}
aircraft_carrier_request_proxy.hidden = true
aircraft_carrier_request_proxy.hidden_in_factoriopedia = true
aircraft_carrier_request_proxy.selectable_in_game = false
aircraft_carrier_request_proxy.minable = nil
aircraft_carrier_request_proxy.inventory_size = 800
aircraft_carrier_request_proxy.open_sound = nil
aircraft_carrier_request_proxy.close_sound = nil
aircraft_carrier_request_proxy.opened_duration = 0
aircraft_carrier_request_proxy.collision_box = {{-0.1, -0.1}, {0.1, 0.1}}
aircraft_carrier_request_proxy.collision_mask = {layers = {}}
aircraft_carrier_request_proxy.selection_box = {{0, 0}, {0, 0}}
aircraft_carrier_request_proxy.selection_priority = 0
aircraft_carrier_request_proxy.corpse = nil
aircraft_carrier_request_proxy.damaged_trigger_effect = nil
aircraft_carrier_request_proxy.fast_replaceable_group = nil
aircraft_carrier_request_proxy.next_upgrade = nil
aircraft_carrier_request_proxy.allow_copy_paste = false
aircraft_carrier_request_proxy.animation = {
  layers = {
    {
      filename = "__core__/graphics/empty.png",
      priority = "extra-high",
      width = 1,
      height = 1,
      frame_count = 1,
      scale = 1
    }
  }
}

local aircraft_carrier_roboport_visual = {
  type = "simple-entity-with-force",
  name = "aircraft-carrier-roboport-visual",
  localised_name = {"entity-name.aircraft-carrier"},
  localised_description = {"entity-description.aircraft-carrier"},
  icons = aircraft_carrier_icons,
  icon = nil,
  render_layer = "higher-object-above",
  flags = {
    "placeable-off-grid",
    "not-on-map",
    "not-blueprintable",
    "not-deconstructable"
  },
  hidden_in_factoriopedia = true,
  selectable_in_game = false,
  allow_copy_paste = false,
  max_health = 1,
  minable = nil,
  collision_box = {{-0.1, -0.1}, {0.1, 0.1}},
  collision_mask = {layers = {}},
  selection_box = {{0, 0}, {0, 0}},
  corpse = nil,
  damaged_trigger_effect = nil,
  picture = {
    layers = {
      make_shifted_sprite(roboport_base.base and roboport_base.base.layers and roboport_base.base.layers[1], 0, -0.7, 0.85),
      make_shifted_sprite(roboport_base.base_patch, 0, -0.7, 0.85),
    }
  }
}

local aircraft_carrier_landing_pad_visual = {
  type = "simple-entity-with-force",
  name = "aircraft-carrier-landing-pad-visual",
  localised_name = {"entity-name.aircraft-carrier"},
  localised_description = {"entity-description.aircraft-carrier"},
  icons = aircraft_carrier_icons,
  icon = nil,
  render_layer = "higher-object-above",
  flags = {
    "placeable-off-grid",
    "not-on-map",
    "not-blueprintable",
    "not-deconstructable"
  },
  hidden_in_factoriopedia = true,
  selectable_in_game = false,
  allow_copy_paste = false,
  max_health = 1,
  minable = nil,
  collision_box = {{-0.1, -0.1}, {0.1, 0.1}},
  collision_mask = {layers = {}},
  selection_box = {{0, 0}, {0, 0}},
  corpse = nil,
  damaged_trigger_effect = nil,
  picture = {
    layers = {
      make_shifted_sprite(request_depot_base.animation and request_depot_base.animation.layers and request_depot_base.animation.layers[1], 0, -0.45, 0.95),
    }
  }
}

local aircraft_carrier_power_interface = {
  type = "electric-energy-interface",
  name = "aircraft-carrier-power-interface",
  localised_name = {"entity-name.aircraft-carrier"},
  localised_description = {"entity-description.aircraft-carrier"},
  icon = "__core__/graphics/empty.png",
  icon_size = 1,
  flags = {
    "placeable-off-grid",
    "not-on-map",
    "not-blueprintable",
    "not-deconstructable"
  },
  hidden = true,
  hidden_in_factoriopedia = true,
  selectable_in_game = false,
  allow_copy_paste = false,
  collision_box = {{-0.1, -0.1}, {0.1, 0.1}},
  collision_mask = {layers = {}},
  selection_box = {{0, 0}, {0, 0}},
  max_health = 1,
  corpse = nil,
  energy_source = {
    type = "electric",
    buffer_capacity = "200MJ",
    usage_priority = "secondary-output",
    input_flow_limit = "0W",
    output_flow_limit = "100MW",
    drain = "0W"
  },
  energy_production = "0W",
  energy_usage = "0W",
  gui_mode = "none",
  picture = {
    filename = "__core__/graphics/empty.png",
    width = 1,
    height = 1
  }
}

local aircraft_carrier_power_pole = table.deepcopy(power_pole_base)
aircraft_carrier_power_pole.name = "aircraft-carrier-power-pole"
aircraft_carrier_power_pole.localised_name = {"entity-name.aircraft-carrier"}
aircraft_carrier_power_pole.localised_description = {"entity-description.aircraft-carrier"}
aircraft_carrier_power_pole.flags = {
  "placeable-off-grid",
  "not-on-map",
  "not-blueprintable",
  "not-deconstructable"
}
aircraft_carrier_power_pole.hidden = true
aircraft_carrier_power_pole.hidden_in_factoriopedia = true
aircraft_carrier_power_pole.selectable_in_game = false
aircraft_carrier_power_pole.allow_copy_paste = false
aircraft_carrier_power_pole.minable = nil
aircraft_carrier_power_pole.next_upgrade = nil
aircraft_carrier_power_pole.fast_replaceable_group = nil
aircraft_carrier_power_pole.max_health = 1
aircraft_carrier_power_pole.collision_box = {{-0.1, -0.1}, {0.1, 0.1}}
aircraft_carrier_power_pole.collision_mask = {layers = {}}
aircraft_carrier_power_pole.selection_box = {{0, 0}, {0, 0}}
aircraft_carrier_power_pole.maximum_wire_distance = 0
aircraft_carrier_power_pole.supply_area_distance = 8
aircraft_carrier_power_pole.corpse = nil
aircraft_carrier_power_pole.damaged_trigger_effect = nil
aircraft_carrier_power_pole.pictures = {
  layers = {
    {
      filename = "__core__/graphics/empty.png",
      width = 1,
      height = 1,
      direction_count = 4,
      line_length = 4
    }
  }
}


data:extend{
  battleship,
  indep_battleship,
  aircraft_carrier,
  indep_aircraft_carrier,
  battleship_cannon_1,
  battleship_cannon_2,
  battleship_cannon_3,
  battleship_cannon_4,
  patrol_boat,
  indep_patrol_boat,
  missile_turret,
  aircraft_carrier_roboport,
  aircraft_carrier_landing_pad,
  aircraft_carrier_request_proxy,
  aircraft_carrier_roboport_visual,
  aircraft_carrier_landing_pad_visual,
  aircraft_carrier_power_interface,
  aircraft_carrier_power_pole
}
