local patrol_boat_icons = {
  {
    icon = GRAPHICSPATH .. "icons/boat.png",
    icon_size = 64,
    tint = {0.7, 0.9, 1}
  },
  {
    icon = "__base__/graphics/icons/artillery-turret.png",
    icon_size = 64,
    scale = 0.4,
    shift = {0, 18}
  }
}

data:extend{
  {
    type = "selection-tool",
    name = "patrol-boat-protect-tool",
    icons = patrol_boat_icons,
    icon = nil,
    flags = {"only-in-cursor", "spawnable"},
    stack_size = 1,
    always_include_tiles = true,
    select = {
      border_color = {r = 0.5, g = 0.9, b = 1},
      cursor_box_type = "train-visualization",
      mode = {"any-entity"}
    },
    alt_select = {
      border_color = {r = 1, g = 0.8, b = 0.2},
      cursor_box_type = "train-visualization",
      mode = {"any-entity"}
    }
  },
  {
    type = "shortcut",
    name = "patrol-boat-protect-shortcut",
    order = "b[boat]-p[patrol-boat-protect]",
    action = "spawn-item",
    item_to_spawn = "patrol-boat-protect-tool",
    icons = patrol_boat_icons,
    icon = nil,
    small_icon = GRAPHICSPATH .. "icons/boat.png",
    small_icon_size = 64,
    toggleable = false,
    associated_control_input = "patrol-boat-protect-tool",
    localised_name = {"shortcut-name.patrol-boat-protect-shortcut"}
  },
  {
    type = "custom-input",
    name = "patrol-boat-protect-tool",
    key_sequence = ""
  }
}
