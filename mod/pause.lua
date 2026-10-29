-- Script pause has a visible, resumable mod UI; native multiplayer pause is separate.
local M={}
local function plain(name)
  return string.gsub(name or "Server administrator","[%c%[%]]","")
end

function M.sync_player(player)
  if not player.valid then return end
  local old=player.gui.screen.ftb_pause_notice
  if not game.tick_paused then if old then old.destroy() end;return end
  local actor=storage.ftb_pause_info and storage.ftb_pause_info.actor or "伺服器管理員"
  if old and old.tags.actor==actor and old.tags.admin==player.admin then return end
  if old then old.destroy() end
  local frame=player.gui.screen.add{type="frame",name="ftb_pause_notice",direction="vertical",
    caption="遊戲已暫停",tags={actor=actor,admin=player.admin}}
  frame.auto_center=true
  frame.add{type="label",caption=plain(actor).." 暫停了遊戲"}
  frame.add{type="label",caption="遊戲管理員可在此恢復；也可使用 /ftb-resume。"}
  local button=frame.add{type="button",name="ftb_resume_game",caption="恢復遊戲"}
  button.enabled=player.admin
end

function M.sync()
  for _,player in pairs(game.connected_players) do M.sync_player(player) end
end

function M.set(paused,actor,source)
  actor=plain(actor)
  local changed=game.tick_paused~=paused
  if changed then
    game.tick_paused=paused
    storage.ftb_pause_info=paused and {actor=actor,source=source,tick=game.tick} or nil
    storage.ftb_last_pause_action={actor=actor,source=source,paused=paused,tick=game.tick,
      serial=(storage.ftb_last_pause_action and storage.ftb_last_pause_action.serial or 0)+1}
    game.print("[監控台] "..actor..(paused and " 暫停了遊戲。" or " 恢復了遊戲。"))
  end
  M.sync()
  return {schema_version=2,tick_paused=game.tick_paused,tick=game.tick,changed=changed,
    pause_info=storage.ftb_pause_info,last_action=storage.ftb_last_pause_action}
end

function M.player_action(index,paused)
  local player=game.get_player(index)
  if not player or not player.admin then
    if player then player.print("只有遊戲管理員可以暫停或恢復。") end
    return false
  end
  M.set(paused,player.name.."（遊戲管理員）","game")
  return true
end

function M.click(event)
  if event.element and event.element.valid and event.element.name=="ftb_resume_game" then
    M.player_action(event.player_index,false)
  end
end

commands.add_command("ftb-resume","Resume monitoring pause (game administrators only)",function(event)
  if event.player_index then M.player_action(event.player_index,false)
  else rcon.print(helpers.table_to_json(M.set(false,"伺服器管理員","server"))) end
end)
commands.add_command("ftb-admin-pause","Pause game (game administrators only)",function(event)
  if event.player_index then M.player_action(event.player_index,true)
  else rcon.print(helpers.table_to_json(M.set(true,"伺服器管理員","server"))) end
end)
script.on_event(defines.events.on_gui_click,M.click)
script.on_event(defines.events.on_player_joined_game,function(event) M.sync_player(game.get_player(event.player_index)) end)
script.on_event({defines.events.on_player_promoted,defines.events.on_player_demoted},function(event)
  M.sync_player(game.get_player(event.player_index))
end)
return M
