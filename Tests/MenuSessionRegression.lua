local menu=require'ixus_menu'
local function exercise(requests,keep_off)
 local ticks=0; local lights={}; local events={}; local replies={}; local fn
 local env=setmetatable({
  get_tick_count=function() return ticks end,
  sleep=function(ms) ticks=ticks+ms end,
  read_usb_msg=function(ms) ticks=ticks+ms; return table.remove(requests,1) end,
  write_usb_msg=function(value) replies[#replies+1]=value end,
  set_backlight=function(value) lights[#lights+1]=value end,
  exit_alt=function() end,enter_alt=function() end,
  click=function(key) assert(key=='menu'); events[#events+1]='click-menu' end,
  get_prop=function() return 0 end,set_aflock=function() end,
  get_levent_def=function(name) return name,1,0 end,
  post_levent_for_npt=function(name) assert(not name:find('SwTwo')); events[#events+1]=name end,
  post_levent_to_ui=function(name) assert(not name:find('SwTwo')); events[#events+1]=name end,
  get_shooting=function() return true end
 },{__index=_G})
 fn=assert(load(menu.source('return {modeName="P",mode=2}',keep_off),nil,'t',env))
 fn(); env.restore()
 return replies,lights,events,ticks
end
local replies,lights,events=exercise({'key:1','state','ping','key:3','key:2','key:0','key:9','quit'},true)
assert(#replies==9 and replies[3].state.modeName=='P' and replies[4].state.mode==2)
assert(lights[#lights]==0,'Normal exit should preserve the chosen off policy')
local text=table.concat(events,',')
assert(text:find('PressFuncButton',1,true) and text:find('PressDownButton',1,true) and text:find('PressSetButton',1,true))
replies,lights,events=exercise({},true)
assert(lights[#lights]==1,'Idle timeout must restore the backlight')
replies,lights,events=exercise({'key:999','quit'},false)
assert(replies[2].ok==false and #events==0,'Invalid key must not emit an event')
print('PASS: native menu preserves state reads, rejects invalid keys and restores backlight on idle timeout')

local function bitmap(alpha)
 return {to_lbuf_packed_rgba=function() return {string=function() return alpha end} end}
end
assert(menu.is_main_bitmap(bitmap(string.rep(string.char(255),256))))
assert(not menu.is_main_bitmap(bitmap(string.rep(string.char(0),256))))
assert(not menu.is_main_bitmap(bitmap(string.rep(string.char(255),64)..string.rep(string.char(0),192))))
print('PASS: native MENU detection uses bitmap opacity rather than scene brightness')
