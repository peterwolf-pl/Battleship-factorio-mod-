local function unlock(recipe)
  return {
    type = "unlock-recipe",
    recipe = recipe
  }
end

local prereqs = {"military-3", "artillery"}

-- Fix A: only depend on cargo_ships if it exists (pelagos removes it)
if data.raw.technology["cargo_ships"] then
  table.insert(prereqs, 1, "cargo_ships")
else
  -- fallback prereq that should exist in vanilla + most overhauls
  -- pick one that fits your progression
  if data.raw.technology["automobilism"] then
    table.insert(prereqs, 1, "automobilism")
  elseif data.raw.technology["engine"] then
    table.insert(prereqs, 1, "engine")
  elseif data.raw.technology["military-2"] then
    table.insert(prereqs, 1, "military-2")
  end
end

data:extend{
  {
    type = "technology",
    name = "battleship",
    icon = GRAPHICSPATH .. "technology/cargo_ships.png",
    icon_size = 256,
    effects = {
      unlock("battleship"),
      unlock("patrol-boat")
    },
    prerequisites = prereqs,
    unit = {
      count = 250,
      ingredients = {
        {"automation-science-pack", 100},
        {"logistic-science-pack", 100},
        {"military-science-pack", 100},
        {"chemical-science-pack", 100}
      },
      time = 30
    },
    order = "c-g-a"
  }
}