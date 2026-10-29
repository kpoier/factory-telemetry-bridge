-- Caches are ephemeral. Only explicit server control commands change the world.
local map_detail=require("map_detail")
local pause=require("pause")
local context_export=require("context_export")
local precision = defines.flow_precision_index.one_minute
local chunk_cache, pole_cache, pole_key = nil, {}, nil
local revision = 0
local hex_bytes={}
for byte=0,255 do hex_bytes[string.char(byte)]=string.format("%02x",byte) end
local dirty_revision, dirty_ring = 0, {}
local status_names = {}
for name, value in pairs(defines.entity_status) do status_names[value] = name end
local entity_types = {"assembling-machine", "furnace", "mining-drill", "electric-pole",
  "generator", "solar-panel", "accumulator", "boiler", "lab", "radar",
  "train-stop", "straight-rail", "curved-rail-a", "curved-rail-b", "storage-tank",
  "pipe", "pipe-to-ground", "pump", "offshore-pump", "infinity-pipe", "heat-pipe",
  "power-switch", "inserter", "transport-belt", "underground-belt", "splitter",
  "loader", "loader-1x1", "arithmetic-combinator", "decider-combinator",
  "constant-combinator", "selector-combinator"}

local function context()
  local force = game.forces[settings.global["ftb-force"].value]
  local surface = game.surfaces[settings.global["ftb-surface"].value]
  if not force or not surface then error("FTB: configured force or surface does not exist") end
  return force, surface
end

local function flow(stats, name, category)
  return stats.get_flow_count{name=name, category=category, precision_index=precision}
end

local function production(force, surface, kind)
  local stats = kind == "fluid" and force.get_fluid_production_statistics(surface)
    or force.get_item_production_statistics(surface)
  local names, watched = {}, {}
  for name in pairs(stats.input_counts) do names[name] = true end
  for name in pairs(stats.output_counts) do names[name] = true end
  if kind == "item" then
    for name in string.gmatch(settings.global["ftb-watch-items"].value, "[^,%s]+") do
      if prototypes.item[name] then names[name], watched[name] = true, true end
    end
  end
  local result = {}
  for name in pairs(names) do
    local produced, consumed = flow(stats, name, "input"), flow(stats, name, "output")
    result[#result+1] = {name=name, kind=kind, produced_per_min=produced,
      consumed_per_min=consumed, net_per_min=produced-consumed, watched=watched[name] or false}
  end
  table.sort(result, function(a,b)
    if a.produced_per_min == b.produced_per_min then return a.name < b.name end
    return a.produced_per_min > b.produced_per_min
  end)
  return result
end

local function chunks(force, surface)
  local key = force.name .. ":" .. surface.name
  if not chunk_cache or chunk_cache.key ~= key then
    local list = {}
    for chunk in surface.get_chunks() do
      if force.is_chunk_charted(surface, chunk) then list[#list+1] = {x=chunk.x,y=chunk.y} end
    end
    local spawn=force.get_spawn_position(surface)
    table.sort(list, function(a,b)
      local da=(a.x*32+16-spawn.x)^2+(a.y*32+16-spawn.y)^2
      local db=(b.x*32+16-spawn.x)^2+(b.y*32+16-spawn.y)^2
      if da ~= db then return da < db end
      if a.x == b.x then return a.y < b.y end return a.x < b.x
    end)
    revision = revision + 1
    chunk_cache = {key=key, list=list, revision=revision}
    if pole_key ~= key then pole_cache, pole_key = {}, key end
    local present = {}
    for _,c in pairs(list) do present[c.x..","..c.y] = true end
    for k in pairs(pole_cache) do if not present[k] then pole_cache[k] = nil end end
  end
  return chunk_cache
end

local function power(force, surface)
  local networks, seen, generated, consumed = {}, {}, 0, 0
  local scanned = 0
  for _, poles in pairs(pole_cache) do
    scanned = scanned + 1
    for _, pole in pairs(poles) do
      if pole.valid and pole.force == force and pole.surface == surface then
        local id = pole.electric_network_id
        if id and not seen[id] then
          seen[id] = true
          local stats = pole.electric_network_statistics
          local production_w, consumption_w = 0, 0
          -- Electric GUI: input/left = production, output/middle = consumption.
          for name in pairs(stats.input_counts) do production_w = production_w + flow(stats,name,"input")*60 end
          for name in pairs(stats.output_counts) do consumption_w = consumption_w + flow(stats,name,"output")*60 end
          generated, consumed = generated+production_w, consumed+consumption_w
          networks[#networks+1] = {id=id, production_mw=production_w/1e6, consumption_mw=consumption_w/1e6}
        end
      end
    end
  end
  table.sort(networks, function(a,b) return a.id < b.id end)
  return {production_mw=generated/1e6, consumption_mw=consumed/1e6,
    networks=networks, network_count=#networks, scanned_chunks=scanned,
    total_chunks=chunk_cache and #chunk_cache.list or 0, coverage="charted chunks scanned; uncharted networks excluded"}
end

local function snapshot()
  local force, surface = context()
  pause.sync()
  local players = {}
  for _, p in pairs(game.connected_players) do
    players[#players+1] = {index=p.index, name=p.name, x=p.position.x, y=p.position.y,
      surface=p.surface.name, force=p.force.name, color=p.color, afk_ticks=p.afk_time,
      online_ticks=p.online_time, admin=p.admin}
  end
  table.sort(players, function(a,b) return a.name < b.name end)
  local research = force.current_research
  local trains = {}
  for _, e in pairs(surface.find_entities_filtered{force=force,type="locomotive",limit=128}) do
    local train = e.train
    if train and train.valid and not trains[train.id] then
      trains[train.id] = {id=train.id,x=e.position.x,y=e.position.y,state=train.state,
        speed=train.speed,manual_mode=train.manual_mode,station=train.station and train.station.backer_name}
    end
  end
  local train_list = {}
  for _, train in pairs(trains) do train_list[#train_list+1] = train end
  local tags = {}
  for _, tag in pairs(force.find_chart_tags(surface)) do
    if #tags >= 200 then break end
    tags[#tags+1]={id=tag.tag_number,text=tag.text,x=tag.position.x,y=tag.position.y}
  end
  return {schema_version=2, mod_version=script.active_mods["factory-telemetry-bridge"], tick=game.tick,
    tick_paused=game.tick_paused, speed=game.speed, force=force.name, surface=surface.name,
    seed=game.default_map_gen_settings.seed, players=players,
    items=production(force,surface,"item"), fluids=production(force,surface,"fluid"),
    power=power(force,surface), sample_window_seconds=60,
    research=research and {name=research.name,level=research.level,progress=force.research_progress},
    trains=train_list,train_limit=128,tags=tags,tag_limit=200,spawn=force.get_spawn_position(surface),
    pause_info=game.tick_paused and storage.ftb_pause_info or nil,last_pause_action=storage.ftb_last_pause_action,
    world_id=storage.ftb_world_id}
end

local function map_batch(cursor, limit, expected_revision)
  local force, surface = context()
  -- Rebuild the list at the start of each full sweep, including new exploration.
  if not cursor or cursor == 0 then chunk_cache = nil end
  local cache = chunks(force,surface)
  cursor = math.max(0, math.floor(tonumber(cursor) or 0))
  if expected_revision and expected_revision ~= cache.revision then cursor = 0 end
  limit = math.max(1, math.min(16, math.floor(tonumber(limit) or 8)))
  local result = {}
  local stop = math.min(#cache.list,cursor+limit)
  for i=cursor+1,stop do
    local c = cache.list[i]
    local chunk,poles=map_detail.read(force,surface,c,entity_types,false)
    pole_cache[c.x..","..c.y]=poles
    result[#result+1]=chunk
  end
  return {schema_version=2, surface=surface.name, force=force.name, seed=game.default_map_gen_settings.seed,
    revision=cache.revision, tick=game.tick, total=#cache.list, cursor=cursor,
    next_cursor=stop, done=stop>=#cache.list, chunks=result}
end

-- Used only by the migration manager against a private copy of a save.
local function validation_probe()
  local force,surface=context()
  local snap=snapshot()
  assert(snap.schema_version==2 and snap.force==force.name,"Invalid bridge snapshot")
  assert(helpers.table_to_json(snap),"Snapshot is not JSON serializable")
  local timer=helpers.create_profiler();timer.stop()
  local checked={snapshot=true,profiler=true,catalogs={},fluid_entities=0,detail_chunks=0,areas=0}
  for kind=0,3 do
    local cursor,total=0,0
    repeat
      local page=context_export.page(kind,cursor,64)
      assert(helpers.table_to_json(page),"Context export is not JSON serializable")
      if kind==0 then checked.catalogs[1]=true;break end
      assert(page.entries and page.next_cursor>=cursor,"Invalid context export page")
      total=total+#page.entries
      if not page.done then assert(page.next_cursor>cursor,"Context export cursor did not advance") end
      cursor=page.next_cursor
      if page.done then break end
    until false
    if kind>0 then checked.catalogs[kind+1]=total end
  end
  local visited={}
  local function check_chunk(c)
    local key=c.x..","..c.y
    if visited[key] or not force.is_chunk_charted(surface,c) then return end
    visited[key]=true
    local detail=map_detail.read(force,surface,c,entity_types,true)
    assert(detail.detailed,"Expected detailed chunk")
    assert(helpers.table_to_json(detail),"Detailed map is not JSON serializable")
    checked.detail_chunks=checked.detail_chunks+1
    local area=context_export.area(c.x*32,c.y*32,(c.x+1)*32,(c.y+1)*32)
    assert(not area.error,area.error)
    assert(area.blueprint_string and area.entities,"Expected native blueprint and entity observations")
    assert(helpers.table_to_json(area),"Area export is not JSON serializable")
    checked.areas=checked.areas+1
  end
  for _,e in pairs(surface.find_entities_filtered{force=force,
      type={"pipe","pipe-to-ground","storage-tank","pump","offshore-pump","boiler","generator",
        "assembling-machine","furnace","fluid-turret","fluid-wagon"},limit=8192}) do
    if e.fluids_count>0 then
      checked.fluid_entities=checked.fluid_entities+1
      check_chunk{x=math.floor(e.position.x/32),y=math.floor(e.position.y/32)}
      if checked.detail_chunks>=8 then break end
    end
  end
  if checked.detail_chunks==0 then
    for chunk in surface.get_chunks() do
      check_chunk(chunk)
      if checked.detail_chunks>0 then break end
    end
  end
  assert(checked.detail_chunks>0,"No charted chunk available to validate bridge")
  local batch=map_batch(0,1)
  assert(batch.schema_version==2,"Invalid bridge map batch")
  checked.map_batch=true
  return checked
end

remote.add_interface("factory_telemetry",{snapshot=snapshot,map_batch=map_batch,validation_probe=validation_probe})
local function world_id()
  if not storage.ftb_world_id then storage.ftb_world_id=game.default_map_gen_settings.seed..":"..game.tick end
  return storage.ftb_world_id
end
script.on_init(world_id)
script.on_configuration_changed(world_id)

local function mark_dirty(surface,position)
  local x,y=math.floor(position.x/32),math.floor(position.y/32)
  for dx=-1,1 do for dy=-1,1 do
    dirty_revision=dirty_revision+1
    dirty_ring[(dirty_revision-1)%4096+1]={revision=dirty_revision,x=x+dx,y=y+dy,surface=surface.name}
  end end
end
local function entity_changed(event)
  local e=event.entity
  if e and e.valid then mark_dirty(e.surface,e.position) end
end
script.on_event({defines.events.on_built_entity,defines.events.on_robot_built_entity,
  defines.events.on_player_mined_entity,defines.events.on_robot_mined_entity,
  defines.events.on_entity_died,defines.events.on_player_rotated_entity,
  defines.events.script_raised_built,defines.events.script_raised_destroy,defines.events.script_raised_revive},entity_changed)
script.on_event({defines.events.on_player_built_tile,defines.events.on_robot_built_tile,
  defines.events.on_player_mined_tile,defines.events.on_robot_mined_tile},function(event)
  local surface=game.surfaces[event.surface_index]
  if surface then for _,tile in pairs(event.tiles) do mark_dirty(surface,tile.position) end end
end)
script.on_event(defines.events.on_chunk_charted,function(event)
  chunk_cache=nil
  if event.force.name~=settings.global["ftb-force"].value then return end
  dirty_revision=dirty_revision+1
  dirty_ring[(dirty_revision-1)%4096+1]={revision=dirty_revision,x=event.position.x,y=event.position.y,
    surface=game.surfaces[event.surface_index].name}
end)
-- Custom read commands avoid /silent-command and its achievement side effects.
local function server_only(event)
  if event.player_index then
    game.get_player(event.player_index).print("Factory telemetry commands are available to the server console only.")
    return false
  end
  return true
end
commands.add_command("ftb-snapshot","Read factory monitoring data",function(event)
  if server_only(event) then rcon.print(helpers.table_to_json(snapshot())) end
end)
commands.add_command("ftb-map","Read a bounded batch of charted chunks",function(event)
  if not server_only(event) then return end
  local args={}
  for token in string.gmatch(event.parameter or "", "%S+") do args[#args+1]=tonumber(token) end
  rcon.print(helpers.table_to_json(map_batch(args[1],args[2],args[3])))
end)
commands.add_command("ftb-index","Read explored chunk coordinates",function(event)
  if not server_only(event) then return end
  local force,surface=context()
  chunk_cache=nil
  local cache=chunks(force,surface)
  rcon.print(helpers.table_to_json({schema_version=2,world_id=world_id(),seed=game.default_map_gen_settings.seed,
    force=force.name,surface=surface.name,tick=game.tick,spawn=force.get_spawn_position(surface),chunks=cache.list}))
end)
commands.add_command("ftb-changes","Read bounded changed chunk journal",function(event)
  if not server_only(event) then return end
  local since=tonumber(event.parameter) or 0
  local _,surface=context()
  local changes={}
  local reset=since>dirty_revision or since<dirty_revision-4096
  if not reset then
    for r=math.max(1,since+1),dirty_revision do
      local entry=dirty_ring[(r-1)%4096+1]
      if entry and entry.surface==surface.name then changes[#changes+1]={x=entry.x,y=entry.y} end
    end
  end
  rcon.print(helpers.table_to_json({schema_version=2,revision=dirty_revision,reset=reset,chunks=changes}))
end)
commands.add_command("ftb-view","Read at most eight requested chunk geometries",function(event)
  if not server_only(event) then return end
  local args={}
  for token in string.gmatch(event.parameter or "","%S+") do
    if not string.match(token,"^-?%d+$") then error("Invalid view argument") end
    args[#args+1]=tonumber(token)
  end
  if #args<3 or #args>17 or #args%2~=1 or (args[1]~=0 and args[1]~=1) then error("Invalid view batch") end
  local timer=helpers.create_profiler()
  local force,surface=context()
  local result={schema_version=2,chunks={},tick=game.tick}
  for i=2,#args,2 do
    local c={x=args[i],y=args[i+1]}
    if math.abs(c.x)>62500 or math.abs(c.y)>62500 then error("Invalid chunk") end
    if force.is_chunk_charted(surface,c) then
      local chunk,poles=map_detail.read(force,surface,c,entity_types,args[1]==1)
      pole_cache[c.x..","..c.y]=poles
      result.chunks[#result.chunks+1]=chunk
    end
  end
  local payload=helpers.table_to_json(result)
  timer.stop()
  rcon.print({"",string.sub(payload,1,-2),',"profile":"',timer,'"}'})
end)
local function chart_tile(x,y)
  if not x or not y or math.abs(x)>62500 or math.abs(y)>62500 then error("Invalid chunk") end
  local force,surface=context()
  local pixels=force.get_chunk_chart(surface,{x=x,y=y})
  local hex=pixels and string.gsub(pixels,".",hex_bytes)
  return {schema_version=2,x=x,y=y,pixels=hex,bytes=pixels and #pixels,
    world_id=world_id(),seed=game.default_map_gen_settings.seed,force=force.name,surface=surface.name,tick=game.tick}
end
commands.add_command("ftb-chart","Read native chart pixels for one explored chunk",function(event)
  if not server_only(event) then return end
  local x,y=string.match(event.parameter or "", "^(-?%d+) (-?%d+)$")
  rcon.print(helpers.table_to_json(chart_tile(tonumber(x),tonumber(y))))
end)
commands.add_command("ftb-charts","Read up to eight native chart tiles",function(event)
  if not server_only(event) then return end
  local timer=helpers.create_profiler()
  local args,tiles={},{}
  for token in string.gmatch(event.parameter or "", "%S+") do
    if not string.match(token,"^-?%d+$") then error("Invalid chunk") end
    args[#args+1]=tonumber(token)
  end
  if #args<2 or #args>16 or #args%2~=0 then error("Invalid tile batch") end
  for i=1,#args,2 do tiles[#tiles+1]=chart_tile(args[i],args[i+1]) end
  local payload=helpers.table_to_json({schema_version=2,tiles=tiles})
  timer.stop()
  rcon.print({"",string.sub(payload,1,-2),',"profile":"',timer,'"}'})
end)
commands.add_command("ftb-pause","Set explicit server pause state",function(event)
  if not server_only(event) then return end
  local request=helpers.json_to_table(event.parameter or "")
  if not request or type(request.paused)~="boolean" or type(request.actor)~="string" or #request.actor>384 then
    error("Invalid pause request")
  end
  local actor=request.actor=="監控台" and request.actor or request.actor.."（監控台）"
  rcon.print(helpers.table_to_json(pause.set(request.paused,actor,"web")))
end)
commands.add_command("ftb-export","Read bounded recipe, equipment and technology context",function(event)
  if not server_only(event) then return end
  local kind,cursor,limit=string.match(event.parameter or "","^(%d+) (%d+) (%d+)$")
  if not kind then error("Invalid export arguments") end
  rcon.print(helpers.table_to_json(context_export.page(tonumber(kind),tonumber(cursor),tonumber(limit))))
end)
commands.add_command("ftb-export-area","Read a charted area and its native blueprint without changing the world",function(event)
  if not server_only(event) then return end
  local left,top,right,bottom=string.match(event.parameter or "","^(-?%d+) (-?%d+) (-?%d+) (-?%d+)$")
  if not left then error("Invalid export area arguments") end
  rcon.print(helpers.table_to_json(context_export.area(tonumber(left),tonumber(top),tonumber(right),tonumber(bottom))))
end)
commands.add_command("ftb-save","Request a server save",function(event)
  if not server_only(event) then return end
  game.server_save()
  rcon.print(helpers.table_to_json({schema_version=2,requested=true,tick=game.tick}))
end)
commands.add_command("ftb-profile","Measure this monitoring mod only",function(event)
  if not server_only(event) then return end
  local timer=helpers.create_profiler()
  snapshot()
  timer.stop()
  -- Profilers only format as LocalisedString; never use elapsed time in simulation logic.
  rcon.print({"",'{"schema_version":2,"snapshot":"',timer,'"}'})
end)
commands.add_command("ftb-end","Monitoring response marker",function(event)
  if server_only(event) then rcon.print("FTB_END") end
end)
script.on_nth_tick(300,function()
  local payload = helpers.table_to_json(snapshot())
  if settings.global["ftb-transport"].value == "udp" then
    local ok=pcall(helpers.send_udp,settings.global["ftb-udp-port"].value,payload,0)
    if ok then return end
  end
  helpers.write_file("factory-telemetry-bridge/state.json",payload,false,0)
end)
