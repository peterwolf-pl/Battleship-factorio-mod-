require("__cargo-ships__/constants")

require("prototypes.entities")
require("prototypes.items")
require("prototypes.patrol_protect")
require("prototypes.recipes")
require("prototypes.technologies")

data:extend({
  {
    type = "custom-input",
    name = "battleship-escort-click",
    key_sequence = "mouse-button-2",
    consuming = "none"
  }
})