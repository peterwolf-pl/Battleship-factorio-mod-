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
artillery_base.minable = nil

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
