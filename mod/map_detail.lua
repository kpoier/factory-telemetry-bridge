-- Geometry is read only. Connections come from the game, never distance guesses.
local M = {}
local status_names, wire_names = {}, {}
for name,value in pairs(defines.entity_status) do status_names[value]=name end
for name,value in pairs(defines.wire_type) do wire_names[value]=name end

function M.read(force,surface,c,types,detail)
  local area={{c.x*32,c.y*32},{(c.x+1)*32,(c.y+1)*32}}
  local entities,poles,wires,pipes={}, {}, {}, {}
  local found=surface.find_entities_filtered{area=area,force=force,type=types,limit=4097}
  local truncated=#found>4096
  for i,e in ipairs(found) do
    if i>4096 then break end
    local p=e.position
    if math.floor(p.x/32)==c.x and math.floor(p.y/32)==c.y then
      local recipe
      if e.type=="assembling-machine" or e.type=="furnace" then
        local r=e.get_recipe();recipe=r and r.name
      end
      local entry={name=e.name,type=e.type,x=p.x,y=p.y,id=e.unit_number,
        direction=e.direction,status=status_names[e.status],recipe=recipe}
      if e.type=="electric-pole" then poles[#poles+1]=e end
      if detail then
        local box=e.bounding_box
        entry.bounds={min_x=box.left_top.x,min_y=box.left_top.y,max_x=box.right_bottom.x,max_y=box.right_bottom.y}
        entry.network_id=e.electric_network_id
        for _,connector in pairs(e.get_wire_connectors(false)) do
          for _,connection in pairs(connector.real_connections) do
            local target=connection.target.owner
            if target.valid and #wires<8192 then
              wires[#wires+1]={from=e.unit_number,to=target.unit_number,
                from_connector=connector.wire_connector_id,to_connector=connection.target.wire_connector_id,
                type=wire_names[connector.wire_type],network_id=entry.network_id,
                x1=p.x,y1=p.y,x2=target.position.x,y2=target.position.y}
            end
          end
        end
        local fluids={}
        for index=1,e.fluids_count do
          local fluid=e.get_fluid(index)
          fluids[#fluids+1]={index=index,name=fluid and fluid.name,amount=fluid and fluid.amount,
            temperature=fluid and fluid.temperature,segment_id=(e.has_fluid_segment(index) and e.get_fluid_segment_id(index) or nil)}
          for _,connection in pairs(e.get_fluid_box_pipe_connections(index) or {}) do
            local target=connection.target
            if target and target.valid and #pipes<8192 then
              local other=target
              local target_connections=target.get_fluid_box_pipe_connections(connection.target_fluidbox_index) or {}
              local endpoint=target_connections[connection.target_pipe_connection_index]
              local pos2=endpoint and endpoint.position or other.position
              pipes[#pipes+1]={from=e.unit_number,to=other.unit_number,from_box=index,
                to_box=connection.target_fluidbox_index,type=connection.connection_type,
                direction=connection.flow_direction,fluid=fluid and fluid.name,
                segment_id=(e.has_fluid_segment(index) and e.get_fluid_segment_id(index) or nil),
                x1=connection.position.x,y1=connection.position.y,x2=pos2.x,y2=pos2.y}
            end
          end
        end
        entry.fluids=fluids
      end
      entities[#entities+1]=entry
    end
  end
  local resources={}
  for _,e in pairs(surface.find_entities_filtered{area=area,type="resource"}) do
    local p=e.position
    if math.floor(p.x/32)==c.x and math.floor(p.y/32)==c.y then
      local r=resources[e.name]
      if not r then
        r={name=e.name,amount=0,count=0,x=0,y=0,min_x=p.x,max_x=p.x,min_y=p.y,max_y=p.y}
        resources[e.name]=r
      end
      r.amount,r.count,r.x,r.y=r.amount+e.amount,r.count+1,r.x+p.x,r.y+p.y
      r.min_x,r.max_x=math.min(r.min_x,p.x),math.max(r.max_x,p.x)
      r.min_y,r.max_y=math.min(r.min_y,p.y),math.max(r.max_y,p.y)
    end
  end
  local ores={}
  for _,r in pairs(resources) do r.x,r.y=r.x/r.count,r.y/r.count;ores[#ores+1]=r end
  return {x=c.x,y=c.y,entities=entities,resources=ores,wires=wires,pipes=pipes,
    detailed=detail,truncated=truncated or #wires>=8192 or #pipes>=8192,tick=game.tick},poles
end
return M
