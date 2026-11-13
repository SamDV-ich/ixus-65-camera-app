-- Exercise the actual host adapter with a simulated camera, including EOF cleanup.
local original_print=print
local original_lines=io.lines
local bridge_path=arg[1]
package.path='Resources/?.lua;'..package.path
local function scenario(lines, fail_off, initially_connected, physical_wake, block_range, fail_focus)
 local connected=initially_connected~=false
 local calls={}; local connects=0; local lcd=1; local mode=1; local focus_range=0; local aflock=1; local half=false; local ticks=0; local props={}; local protected_camera_call=false; local menu_thread; local menu_starts=0; local messages={}; local main_panel=false
 package.preload.propcase=function() return {FLASH_MODE=16,AF_LOCK=193,REAL_FOCUS_MODE=11,FOCUS_STATE=67,ISO_MODE=21,WB_MODE=5,EV_CORRECTION_1=25,EV_CORRECTION_2=26,METERING_MODE=9} end
 package.loaded.capmode=nil
 package.preload.capmode=function() return {
  get=function() return mode end,get_name=function() return mode==0 and 'PLAY' or (mode==2 and 'P' or 'AUTO') end,mode_to_name={[1]='AUTO',[2]='P',[36]='PORTRAIT',[60]='SCN_SNOW',[70]='VIDEO_STD',[80]='UNSUPPORTED'},
  valid=function(value) return value~=80 end,
  set=function(value) mode=value; lcd=1; calls[#calls+1]='canon-mode'; return true end
 } end
 get_buildinfo=function() return {platform='ixus65_sd630',platsub='100a',build_number='test'} end
 get_prop=function(id) if id==11 then return focus_range elseif id==193 then return aflock elseif id==67 then return (half and not fail_focus) and 1 or 0 else return props[id] or 0 end end; get_zoom=function() return 0 end
 get_focus=function() return 1000 end; get_mode=function() return mode~=0 end
 get_vbatt=function() return 3800 end; get_config_value=function(id) return id==2100 and 4200 or 3400 end
 set_prop=function(id,value) props[id]=value end
 set_aflock=function(value) aflock=value and 1 or 0 end
 click=function(key)
  assert(not protected_camera_call,'Camera Lua 5.1 cannot yield through pcall')
  assert(key~='shoot_full'); if key=='menu' then main_panel=not main_panel end; if key~='left' then calls[#calls+1]='key-'..key; return end
  calls[#calls+1]='range-button'
  if not block_range then focus_range=({[0]=1,[1]=3,[3]=0})[focus_range] end
 end
 get_levent_def=function(name) return name,1,0 end
 post_levent_for_npt=function(event)
  assert(not event:find('SwTwo'),'Full shutter is forbidden')
  if event=='PressSwOne' then half=true; calls[#calls+1]='half-press'; return end
  if event=='UnpressSwOne' then half=false; calls[#calls+1]='half-release'; return end
  if event:match('^Press') then
   local names={PressFuncButton='func',PressSetButton='set',PressUpButton='up',PressDownButton='down',PressMacroButton='left',PressLeftButton='left',PressRightButton='right',PressMenuButton='menu',PressDispButton='display',PressTeleButton='zoom_in',PressWideButton='zoom_out'}
   assert(names[event],event); click(names[event])
  end
 end
 post_levent_to_ui=post_levent_for_npt
 enter_alt=function() end
 exit_alt=function() end
 read_usb_msg=function() return coroutine.yield() end
 write_usb_msg=function(value) messages[#messages+1]=value end
 get_tick_count=function() return ticks end
 get_shooting=function() return half end
 get_focus_ok=function() return half and not fail_focus end
 press=function(key) assert(not protected_camera_call,'Camera Lua 5.1 cannot yield through pcall'); assert(key=='shoot_half'); half=true; calls[#calls+1]='half-press' end
 release=function(key) assert(not protected_camera_call,'Camera Lua 5.1 cannot yield through pcall'); assert(key=='shoot_half'); half=false; calls[#calls+1]='half-release' end
 sleep=function(ms) assert(not protected_camera_call,'Camera Lua 5.1 cannot yield through pcall'); ticks=ticks+ms end
 set_backlight=function(value)
  calls[#calls+1]='display'..value; lcd=value
  if fail_off and value==0 then error('timeout after LCD changed') end
 end
 chdk={list_usb_devices=function() return {{product_id=0x30fe}} end}
 cli={execute=function(_,command)
  if command=='play' then mode=0; lcd=1; calls[#calls+1]='canon-play'
  elseif command=='rec' then mode=1; lcd=1; calls[#calls+1]='canon-rec'
  else connects=connects+1; connected=true end
  return true
 end}
 con={is_connected=function() return connected end,
      disconnect=function() calls[#calls+1]='disconnect'; connected=false end,
      exec=function(_,code)
       assert(not menu_thread or coroutine.status(menu_thread)=='dead','Camera script already running')
       menu_starts=menu_starts+1
       menu_thread=coroutine.create(assert(load(code)))
       local ok,err=coroutine.resume(menu_thread); assert(ok,err)
      end,
      write_msg=function(_,message)
       assert(menu_thread and coroutine.status(menu_thread)~='dead','No menu script')
       local ok,err=coroutine.resume(menu_thread,message); assert(ok,err)
      end,
      wait_msg=function() local value=table.remove(messages,1); assert(value,'Missing camera message'); return value end,
      wait_status=function() return {run=menu_thread and coroutine.status(menu_thread)~='dead',timeout=false} end,
      flushmsgs=function() messages={} end,
      execwait=function(_,code)
       assert(not menu_thread or coroutine.status(menu_thread)=='dead','State reads must use existing menu script')
       local env=setmetatable({pcall=function(fn,...)
        protected_camera_call=true
        local results=table.pack(pcall(fn,...))
        protected_camera_call=false
        return table.unpack(results,1,results.n)
       end},{__index=_G})
       return assert(load(code,nil,'t',env))()
      end,
      live_is_api_compatible=function() return true end,
      live={_frame={}}, live_get_frame=function(self,flags) assert(flags==1 or flags==13); self.live._frame.main_panel=main_panel end}
 local bitmap={to_lbuf_packed_rgba=function() return {string=function() return string.rep(main_panel and string.char(255,255,255,255) or string.char(255,255,255,0),4) end} end}
 package.loaded.liveimg={get_bitmap_pimg=function() return bitmap end}
 if _G.ixus_test_pixels then package.loaded.liveimg=_G.ixus_test_pixels end
 local responses={}
 print=function(value) if tostring(value):match('^IXUS_RESULT:') then responses[#responses+1]=value end end
 io.lines=function() local n=0; return function()
  n=n+1
  if physical_wake and n==2 then mode=2; lcd=1; calls[#calls+1]='canon-wake' end
  return lines[n]
 end end
 assert(loadfile(bridge_path))().worker()
 print=original_print; io.lines=original_lines
 return table.concat(calls,','),lcd,connects,responses,menu_starts
end
local calls,lcd=scenario({'display\t0\t\t1','poll\t\t\t2','QUIT'})
assert(calls=='display0,display0,display1,disconnect' and lcd==1,calls)
original_print('PASS: keep-off is reapplied by poll and restored before disconnect')
calls,lcd=scenario({'display\t0\t\t1'})
assert(calls=='display0,display1,disconnect' and lcd==1,calls)
original_print('PASS: EOF also restores display')
calls,lcd=scenario({'display\t0\t\t1','invalid\t\t\t2','QUIT'})
assert(calls:match('display0,display1,disconnect'),calls)
original_print('PASS: rejected command restores screen before disconnect')
calls,lcd=scenario({'display\t0\t\t1','QUIT'},true)
assert(calls:match('display0,display1,disconnect') and lcd==1,calls)
original_print('PASS: timeout after LCD changes still attempts screen restoration')
local _,_,connects,responses=scenario({'poll\t\t\t1','QUIT'},false,false)
assert(connects==0 and responses[1]:match('"ok":false'))
original_print('PASS: background poll does not reconnect a lost session')

local calls,_,_,responses=scenario({'display\t0\t\t1','poll\t\t\t2','display\t1\t\t3','poll\t\t\t4','QUIT'},false,true,true)
assert(calls=='display0,canon-wake,display0,display1,disconnect',calls)
assert(responses[2]:match('"keepBacklightOff":true') and responses[4]:match('"keepBacklightOff":false'))
original_print('PASS: physical mode wake is followed by OFF; disabling policy stops enforcement')
calls=scenario({'poll\t\t\t1','QUIT'})
assert(calls=='disconnect',calls)
original_print('PASS: polling without keep-off never writes backlight')
calls=scenario({'display\t0\t\t1','mode\t2\t\t2','play\t\t\t3','record\t\t\t4','QUIT'})
assert(calls:match('canon%-mode,display0') and calls:match('canon%-play,display0') and calls:match('canon%-rec,display0'),calls)
original_print('PASS: mode, playback and record transitions reapply keep-off before replying')

local _,_,_,responses=scenario({'status\t\t\t1','mode\t60\t\t2','QUIT'})
assert(responses[1]:match('"60":"SCN_SNOW"') and not responses[1]:match('VIDEO_STD') and not responses[1]:match('UNSUPPORTED'),responses[1])
assert(responses[2]:match('"ok":true') and responses[2]:match('"mode":60'),responses[2])
original_print('PASS: camera mode list includes photo modes above 49 and they can be selected')
for _,id in ipairs({70,80,999}) do
 local _,_,_,responses=scenario({'mode\t'..id..'\t\t1','QUIT'})
 assert(responses[1]:match('"ok":false'),responses[1])
end
original_print('PASS: video, unavailable and unknown modes are rejected before switching')

local _,_,_,responses=scenario({'mode\t2\t\t0','focusrange\t1\t\t1','focusrange\t3\t\t2','focusrange\t0\t\t3','QUIT'})
for i,range in ipairs({1,3,0}) do
 assert(responses[i+1]:match('"ok":true') and responses[i+1]:match('"focusRange":'..range) and responses[i+1]:match('"aflock":0'),responses[i+1])
end
original_print('PASS: native focus-range button selects macro, infinity and normal, releasing AF Lock')
local calls,_,_,responses=scenario({'mode\t2\t\t0','focusrange\t3\t\t1','QUIT'},false,true,false,true)
assert(responses[2]:match('"ok":false'),responses[2])
assert(not calls:match('range%-button,range%-button,range%-button,range%-button'),calls)
original_print('PASS: unavailable focus range fails after bounded native button attempts')
local _,_,_,responses=scenario({'focusrange\t2\t\t1','QUIT'})
assert(responses[1]:match('"ok":false'),responses[1])
original_print('PASS: invalid focus range is rejected')

local calls,_,_,responses=scenario({'mode\t2\t\t0','focusnow\t1\t\t1','QUIT'})
assert(responses[2]:match('"ok":true') and responses[2]:match('"aflock":1'),responses[2])
assert(calls:match('half%-press,half%-release'),calls)
local calls,_,_,responses=scenario({'focusnow\t0\t\t1','QUIT'},false,true,false,false,true)
assert(responses[1]:match('"ok":true') and responses[1]:match('"focusSucceeded":false') and calls:match('half%-release'),responses[1])
original_print('PASS: focus now uses half-press only, locks on success and releases on timeout')

local _,_,_,responses=scenario({'mode\t2\t\t0','iso\t80\t\t1','wb\t3\t\t2','ev\t64\t\t3','metering\t2\t\t4','QUIT'})
assert(responses[2]:match('"iso":80') and responses[3]:match('"wb":3') and responses[4]:match('"ev":64') and responses[5]:match('"metering":2'))
local _,_,_,responses=scenario({'ev\t32\t\t1','QUIT'})
assert(responses[1]:match('"ok":false'),responses[1])
original_print('PASS: exposure controls read back values and reject unavailable Auto-mode changes')
local calls,_,_,responses=scenario({'screen\t1\t\t1','key\t1\t\t2','key\t2\t\t3','screen\t0\t\t4','QUIT'})
assert(responses[4]:match('"ok":true') and calls:match('key%-func') and calls:match('key%-up') and calls:match('key%-set'),calls)
local _,_,_,responses=scenario({'screen\t1\t\t1','key\t999\t\t2','QUIT'})
assert(responses[2]:match('"ok":false'),responses[2])
original_print('PASS: native menu accepts bounded logical keys and closes through MENU or SET without autofocus')
local function pixels(channels)
 return {width=function() return 2 end,height=function() return 2 end,
  to_lbuf_packed_rgb=function() return {fwrite=function(_,f) f:write(string.rep(string.char(100),12)) end} end,
  to_lbuf_packed_rgba=function() return {string=function() return string.rep(string.char(0),16) end,fwrite=function(_,f) f:write(string.rep(string.char(255),16)) end} end}
end
_G.ixus_test_pixels={get_viewport_pimg=function() return pixels(3) end,get_bitmap_pimg=function() return pixels(4) end}
local path=os.tmpname()
local hex=path:gsub('.',function(c) return string.format('%02x',c:byte()) end)
local _,_,_,responses=scenario({'screen\t1\t\t1','frame\t\t'..hex..'\t2','QUIT'})
assert(responses[2]:match('"ok":true') and responses[2]:match('"overlay":'),responses[2])
local f=assert(io.open(path..'.rgba','rb')); local overlay=f:read('*a'); f:close()
assert(overlay=='RGBA\n2 2\n'..string.rep(string.char(255),16))
os.remove(path); os.remove(path..'.rgba'); _G.ixus_test_pixels=nil
original_print('PASS: native screen writes the bitmap palette overlay beside the viewport frame')
local skips={}
_G.ixus_test_pixels={get_viewport_pimg=function(_,_,skip) skips[#skips+1]=skip; return pixels(3) end}
local _,_,_,qualityResponses=scenario({'frame\t0\t'..hex..'\t1','frame\t1\t'..hex..'\t2','frame\t9\t'..hex..'\t3','QUIT'})
assert(skips[1]==true and skips[2]==false and #skips==2)
assert(qualityResponses[1]:match('"ok":true') and qualityResponses[2]:match('"ok":true') and qualityResponses[3]:match('"ok":false'))
os.remove(path); _G.ixus_test_pixels=nil
original_print('PASS: preview quality selects full or skipped decoding and rejects invalid requests')

if arg[2] then
 local _,_,_,responses=scenario({'mode\t2\t\t0','status\t\t\t1','QUIT'})
 local f=assert(io.open(arg[2],'w')); f:write((responses[2]:gsub('^IXUS_RESULT:',''))); f:close()
end

local calls,_,_,responses=scenario({'screen\t1\t\t1','key\t102\t\t2','QUIT'})
assert(responses[2]:match('"ok":true') and calls:match('half%-press,key%-up,half%-release'),calls)
original_print('PASS: native button combinations release half-press and cannot send full shutter')

local profile=require'ixus_profile'
assert(not profile.allows(profile.controls('AUTO'),'flash',1))
assert(not profile.allows(profile.controls('SCN_COLOR_ACCENT'),'flash',0))
assert(not profile.allows(profile.controls('SCN_COLOR_SWAP'),'flash',0))
assert(not profile.allows(profile.controls('STITCH'),'flash',0))
assert(not profile.allows(profile.controls('PORTRAIT'),'focuslock',1))
original_print('PASS: Canon mode restrictions exclude unavailable flash and focus-lock choices')

assert(profile.allows(profile.controls('AUTO'),'iso',1))
assert(not profile.allows(profile.controls('AUTO'),'iso',-1))
original_print('PASS: High Auto ISO uses native property value 1 rather than a CHDK ISO table ID')

local _,_,connects,responses=scenario({'focusnow\t0\t\t1','poll\t\t\t2','QUIT'},false,true,false,false,true)
assert(responses[1]:match('"focusSucceeded":false') and responses[2]:match('"ok":true') and connects==0 and responses[1]:match('"connectionGeneration":(%d+)')==responses[2]:match('"connectionGeneration":(%d+)'))
original_print('PASS: ordinary autofocus refusal preserves the connected session and subsequent polling')

local calls,_,_,responses,starts=scenario({'screen\t1\t\t1','key\t0\t\t2','key\t1\t\t3','poll\t\t\t4','key\t3\t\t5','key\t9\t\t6','screen\t0\t\t7','QUIT'})
for _,response in ipairs(responses) do assert(response:match('"ok":true'),response) end
assert(starts==1 and not calls:find('half-press',1,true),calls)
original_print('PASS: MENU closes by bitmap readback before one persistent FUNC session; no autofocus is started')

local previous_capture=package.loaded.ixus_capture
package.loaded.ixus_capture={attempt=function() return {captureFailed=true,captureError='Download failed',shotRequested=true} end}
local calls,_,connections,replies=scenario({'take\t0\t\t1','poll\t\t\t2','QUIT'})
assert(replies[1]:match('"captureFailed":true') and replies[2]:match('"ok":true'))
assert(connections==0 and select(2,calls:gsub('disconnect',''))==1,calls)
package.loaded.ixus_capture=previous_capture
original_print('PASS: a recoverable capture failure preserves the existing USB session and subsequent polling')
