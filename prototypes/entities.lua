local battleship_icons = {
  {
    icon = GRAPHICSPATH .. "icons/cargoship_icon.png",
    icon_size = 64,
    tint = {0.75, 0.75, 0.95}
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
    tint = {0.7, 0.9, 1}
  },
  {
    icon = "__base__/graphics/icons/rocket-launcher.png",
    icon_size = 64,
    scale = 0.5,
    shift = {8, 8}
  }
}

local cargo_ship = data.raw["cargo-wagon"]["cargo_ship"]
local boat = data.raw["cargo-wagon"]["boat"]
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

local function strip_turret_graphics(turret)
  if not turret then return end
  -- Common turret fields (optional depending on base prototype)
  if turret.folded_animation ~= nil then turret.folded_animation = make_empty_rotated_animation() end
  if turret.preparing_animation ~= nil then turret.preparing_animation = make_empty_rotated_animation() end
  if turret.prepared_animation ~= nil then turret.prepared_animation = make_empty_rotated_animation() end
  if turret.attacking_animation ~= nil then turret.attacking_animation = make_empty_rotated_animation() end
  if turret.starting_attack_animation ~= nil then turret.starting_attack_animation = make_empty_rotated_animation() end
  if turret.ending_attack_animation ~= nil then turret.ending_attack_animation = make_empty_rotated_animation() end

  if turret.base_picture ~= nil then turret.base_picture = make_empty_rotated_sprite() end
  if turret.base_picture_render_layer ~= nil then turret.base_picture_render_layer = "object" end

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

    -- Battleship-graphics patrolboat frames are 474x458.        @#$@#$@##@$@#$@#$@#$@#$@#$@#$@#$@#$@#$@#$@#$@$
    s.width = 474
    s.height = 458
    -- s.scale = 1
    -- Prevent HR mismatch / missing files.
    s.hr_version = nil

    -- Atlas/stripe-only fields don't apply for per-file directions.
    s.slice = nil
    s.stripes = nil

    return s
  end

  local function patch_layers(layers)
    if type(layers) ~= "table" then return end
    for i = 1, #layers do
      local layer = layers[i]
      if type(layer) == "table" then
        if layer.draw_as_shadow then
          layer.scale = 0.4
          -- Custom patrolboat sprites are shorter than the original boat graphics,
          -- so the inherited shadow often ends up too far away. Nudge it closer.    $%$%$%$%$%$%$%$%$%$%$%$%$%$%$%$%$%$%$%$%$$%$%$%$%$%$%$%$%$
          local adj_x, adj_y = 0 , -0.5
          if type(layer.shift) == "table" and type(layer.shift[1]) == "number" and type(layer.shift[2]) == "number" then
            layer.shift = {layer.shift[1] + adj_x, layer.shift[2] + adj_y}
          else
            layer.shift = {adj_x, adj_y}
          end
        else
          -- Replace only visible sprite layers.
          local new_layer = make_new_sprite(layer)
          if new_layer then
            layers[i] = new_layer
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
  battleship.pictures.rotated.layers[1].tint = {0.75, 0.75, 0.95}
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
  indep_battleship.animation = {layers = cargo_ship_layers}
  indep_battleship.pictures = nil
  indep_battleship.water_reflection = cargo_ship.water_reflection
end
-- Apply speed multiplier
if indep_battleship.max_speed then
  indep_battleship.max_speed = indep_battleship.max_speed * battleship_speed_multiplier
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

try_apply_patrolboat_graphics(patrol_boat)

local indep_boat = data.raw["car"]["indep-boat"]
local indep_patrol_boat = table.deepcopy(indep_boat)
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


data:extend{
  battleship,
  indep_battleship,
  battleship_cannon_1,
  battleship_cannon_2,
  battleship_cannon_3,
  battleship_cannon_4,
  patrol_boat,
  indep_patrol_boat,
  missile_turret
}