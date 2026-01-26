data:extend{
  {
    type = "recipe",
    name = "battleship",
    enabled = false,
    energy_required = 25,
    ingredients = {
      {type="item", name="steel-plate", amount=400},
      {type="item", name="engine-unit", amount=180},
      {type="item", name="iron-gear-wheel", amount=190},
      {type="item", name="electronic-circuit", amount=40},
      {type="item", name="explosives", amount=50},
      {type="item", name="artillery-turret", amount=4}
    },
    results = {{type="item", name="battleship", amount=1}}
  },
  {
    type = "recipe",
    name = "patrol-boat",
    enabled = false,
    energy_required = 8,
    ingredients = {
      {type="item", name="steel-plate", amount=80},
      {type="item", name="engine-unit", amount=25},
      {type="item", name="iron-gear-wheel", amount=20},
      {type="item", name="electronic-circuit", amount=15},
      {type="item", name="explosives", amount=25},
      {type="item", name="rocket-launcher", amount=1}
    },
    results = {{type="item", name="patrol-boat", amount=1}}
  }
}
