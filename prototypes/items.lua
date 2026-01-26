local subgroup_ship = "water_transport"

if mods["SchallTransportGroup"] then
  subgroup_ship = "water_transport2"
end

data:extend{
  {
    type = "item-with-entity-data",
    name = "battleship",
    icons = {
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
    },
    subgroup = subgroup_ship,
    order = "a[water-system]-g[battleship]",
    place_result = "indep-battleship",
    placeable_by = {{item = "battleship", count = 1}},
    stack_size = 1
  },
  {
    type = "item-with-entity-data",
    name = "patrol-boat",
    icons = {
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
    },
    subgroup = subgroup_ship,
    order = "a[water-system]-f[patrol-boat]",
    place_result = "indep-patrol-boat",
    stack_size = 1
  }
}
