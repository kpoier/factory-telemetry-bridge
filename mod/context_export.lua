-- On-demand, read-only context for a human to take to another AI conversation.
local M={}
local indexes={}
local function names(source)
  local result={}
  for name in pairs(source or {}) do result[#result+1]=name end
  table.sort(result)
  return result
end
local function context()
  return game.forces[settings.global["ftb-force"].value],game.surfaces[settings.global["ftb-surface"].value]
end
local function identity(force,surface)
  return {schema_version=2,world_id=storage.ftb_world_id,force=force.name,surface=surface.name,tick=game.tick,
    seed=game.default_map_gen_settings.seed,mods=script.active_mods}
end
function M.metadata()
  local force,surface=context()
  local result=identity(force,surface)
  result.schema_version=2
  result.researched={}
  for name,t in pairs(force.technologies) do
    if t.researched then result.researched[#result.researched+1]={name=name,level=t.level} end
  end
  table.sort(result.researched,function(a,b)return a.name<b.name end)
  result.enabled_recipes={}
  for name,r in pairs(force.recipes) do
    if r.enabled then result.enabled_recipes[#result.enabled_recipes+1]=name end
  end
  table.sort(result.enabled_recipes)
  result.research_queue={}
  for _,t in pairs(force.research_queue or {}) do result.research_queue[#result.research_queue+1]=t.name end
  result.directions=defines.direction
  result.tick_paused=game.tick_paused
  result.game_speed=game.speed
  result.current_research=force.current_research and {name=force.current_research.name,progress=force.research_progress}
  return result
end
local function recipe(r)
  return {name=r.name,localised_name=r.localised_name,category=r.categories[1],categories=r.categories,enabled=r.enabled,hidden=r.hidden,
    crafting_seconds=r.energy,ingredients=r.ingredients,products=r.products,productivity_bonus=r.productivity_bonus,
    maximum_productivity=r.prototype.maximum_productivity}
end
local function machine(p)
  local boxes={}
  for _,b in pairs(p.fluidbox_prototypes or {}) do
    boxes[#boxes+1]={index=b.index,production_type=b.production_type,filter=b.filter and b.filter.name,
      volume=b.get_volume("normal"),
      pipe_connections=b.pipe_connections}
  end
  local crafting=p.type=="assembling-machine" or p.type=="furnace" or p.type=="rocket-silo"
  return {name=p.name,type=p.type,localised_name=p.localised_name,items_to_place=p.items_to_place_this,
    collision_box=p.collision_box,selection_box=p.selection_box,collision_mask=p.collision_mask,
    tile_width=p.tile_width,tile_height=p.tile_height,crafting_categories=names(p.crafting_categories),
    normal_crafting_speed=crafting and p.get_crafting_speed("normal") or nil,
    module_slots=p.module_inventory_size,allowed_effects=p.allowed_effects,fluidboxes=boxes,
    belt_speed_tiles_per_tick=p.belt_speed,max_underground_distance=p.max_underground_distance,
    inserter_pickup_position=p.inserter_pickup_position,inserter_drop_position=p.inserter_drop_position,
    normal_max_energy_usage_joules_per_tick=p.get_max_energy_usage("normal"),
    normal_supply_area_distance=p.type=="electric-pole" and p.get_supply_area_distance("normal") or nil,
    normal_max_wire_distance=p.get_max_wire_distance("normal")}
end
local function technology(t)
  local unlocks={}
  for _,e in pairs(t.prototype.effects or {}) do
    if e.type=="unlock-recipe" then unlocks[#unlocks+1]=e.recipe end
  end
  table.sort(unlocks)
  return {name=t.name,localised_name=t.localised_name,researched=t.researched,enabled=t.enabled,level=t.level,
    prerequisites=names(t.prerequisites),unlocks=unlocks,research_ingredients=t.research_unit_ingredients,
    research_count=t.research_unit_count,research_seconds_per_unit=t.research_unit_energy}
end
function M.page(kind,cursor,limit)
  local force,surface=context()
  if kind==0 then return M.metadata() end
  if kind<1 or kind>3 or cursor<0 or limit<1 or limit>64 then error("Invalid export page") end
  local sources={force.recipes,prototypes.entity,force.technologies}
  local source=sources[kind]
  if cursor==0 or not indexes[kind] then
    local list={}
    for name,p in pairs(source) do
      if kind~=2 or (p.items_to_place_this and #p.items_to_place_this>0) then list[#list+1]=name end
    end
    table.sort(list);indexes[kind]=list
  end
  local list=indexes[kind]
  local result=identity(force,surface)
  result.entries={};result.total=#list
  result.next_cursor=math.min(#list,cursor+limit)
  result.done=result.next_cursor>=#list
  for i=cursor+1,result.next_cursor do
    local p=source[list[i]]
    result.entries[#result.entries+1]=kind==1 and recipe(p) or kind==2 and machine(p) or technology(p)
  end
  return result
end
local inventories={
  ["assembling-machine"]={"assembling_machine_input","assembling_machine_output","assembling_machine_modules"},
  furnace={"furnace_source","furnace_result","furnace_modules"},
  lab={"lab_input","lab_modules"},container={"chest"},["logistic-container"]={"chest"},
  ["mining-drill"]={"mining_drill_modules"},roboport={"roboport_robot","roboport_material"}
}
-- Keep the existing exported keys; only Factorio's enum names changed.
local inventory_aliases={
  assembling_machine_input="crafter_input",assembling_machine_output="crafter_output",
  assembling_machine_modules="crafter_modules",furnace_source="crafter_input",
  furnace_result="crafter_output",furnace_modules="crafter_modules"
}
local function observe(e)
  local inv={}
  for _,name in pairs(inventories[e.type] or {}) do
    local inventory=e.get_inventory(defines.inventory[inventory_aliases[name] or name])
    if inventory then inv[name]=inventory.get_contents() end
  end
  if e.burner then
    inv.fuel=e.burner.inventory.get_contents()
    if e.burner.burnt_result_inventory then inv.burnt_result=e.burner.burnt_result_inventory.get_contents() end
  end
  local fluids={}
  for i=1,e.fluids_count do
    local fluid=e.get_fluid(i)
    fluids[#fluids+1]={index=i,name=fluid and fluid.name,amount=fluid and fluid.amount,
      temperature=fluid and fluid.temperature,segment_id=e.has_fluid_segment(i) and e.get_fluid_segment_id(i) or nil}
  end
  local statuses={}
  for name,value in pairs(defines.entity_status) do statuses[value]=name end
  local r,q
  if e.type=="assembling-machine" or e.type=="furnace" or e.type=="rocket-silo" then r,q=e.get_recipe() end
  return {id=e.unit_number,name=e.name,type=e.type,position=e.position,direction=e.direction,
    quality=e.quality.name,status=statuses[e.status],recipe=r and r.name,recipe_quality=q and q.name,
    crafting_speed=r and e.crafting_speed,productivity_bonus=r and e.productivity_bonus,
    network_id=e.electric_network_id,inventories=inv,fluids=fluids}
end
function M.area(left,top,right,bottom)
  if left>=right or top>=bottom or right-left>256 or bottom-top>256 or
    math.max(math.abs(left),math.abs(top),math.abs(right),math.abs(bottom))>1999999 then error("Invalid export area") end
  local force,surface=context()
  local result=identity(force,surface)
  result.bounds={left=left,top=top,right=right,bottom=bottom}
  for x=math.floor(left/32),math.floor((right-1)/32) do
    for y=math.floor(top/32),math.floor((bottom-1)/32) do
      if not force.is_chunk_charted(surface,{x=x,y=y}) then
        result.error="選取區域包含尚未探索的區塊；請移動地圖中心或縮小匯出範圍。";return result
      end
    end
  end
  local area={{left,top},{right,bottom}}
  local found=surface.find_entities_filtered{area=area,force=force,limit=4097}
  if #found>4096 then result.error="區域設備超過 4096 台；請縮小匯出範圍。";return result end
  result.entities={}
  for _,e in pairs(found) do
    if e.type~="character" and e.type~="entity-ghost" and e.type~="tile-ghost" then result.entities[#result.entities+1]=observe(e) end
  end
  local inventory=game.create_inventory(1)
  local ok,err=pcall(function()
    local bp=inventory[1];bp.set_stack{name="blueprint"}
    local mapping=bp.create_blueprint{surface=surface,force=force,area=area,include_modules=true,
      include_station_names=true,include_trains=false,always_include_tiles=false}
    result.blueprint_string=bp.export_stack()
    result.blueprint_entities=bp.get_blueprint_entities() or {}
    result.blueprint_world_positions={}
    for index,e in pairs(mapping) do result.blueprint_world_positions[#result.blueprint_world_positions+1]={entity_number=index,position=e.position} end
  end)
  inventory.destroy()
  if not ok then error(err) end
  -- Run lengths retain every terrain tile without emitting one record per tile.
  result.terrain_runs={};result.terrain_prototypes={}
  for y=top,bottom-1 do
    local start,name=left,surface.get_tile(left,y).name
    for x=left+1,right do
      local next_name=x<right and surface.get_tile(x,y).name or nil
      if next_name~=name then
        result.terrain_runs[#result.terrain_runs+1]={x=start,y=y,length=x-start,name=name}
        if not result.terrain_prototypes[name] then
          result.terrain_prototypes[name]={collision_mask=prototypes.tile[name].collision_mask}
        end
        start,name=x,next_name
      end
    end
  end
  local obstacles=surface.find_entities_filtered{area=area,force="neutral",
    type={"tree","simple-entity","cliff","simple-entity-with-owner"},limit=513}
  result.neutral_obstacles={};result.obstacles_truncated=#obstacles>512
  for i,e in ipairs(obstacles) do
    if i>512 then break end
    if e.type~="resource" and e.type~="fish" then
      result.neutral_obstacles[#result.neutral_obstacles+1]={name=e.name,type=e.type,position=e.position,bounds=e.bounding_box}
    end
  end
  result.resource_summary={}
  for _,e in pairs(surface.find_entities_filtered{area=area,type="resource"}) do
    local r=result.resource_summary[e.name] or {count=0,amount=0}
    r.count=r.count+1;r.amount=r.amount+e.amount;result.resource_summary[e.name]=r
  end
  return result
end
return M
