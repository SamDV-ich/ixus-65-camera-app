-- Exercise the actual host adapter with a simulated camera, including EOF cleanup.
local original_print=print
local original_lines=io.lines
local bridge_path=arg[1]
package.path='Resources/?.lua;'..package.path
local function scenario(lines, fail_off, initially_connected, physical_wake, block_range, fail_focus)
 local connected=initially_connected~=false
 local calls={}; local connects=0; local lcd=1; local mode=1; local focus_range=0; local aflock=1; local half=false; local ticks=0
 package.preload.propcase=function() return {FLASH_MODE=16,AF_LOCK=193,REAL_FOCUS_MODE=11,FOCUS_STATE=67} end
 package.loaded.capmode=nil
 package.preload.capmode=function() return {
  get=function() return mode end,get_name=function() return mode==0 and 'PLAY' or (mode==2 and 'P' or 'AUTO') end,mode_to_name={[1]='AUTO',[2]='P',[36]='PORTRAIT',[60]='SCN_SNOW',[70]='VIDEO_STD',[80]='UNSUPPORTED'},
  valid=function(value) return value~=80 end,
  set=function(value) mode=value; lcd=1; calls[#calls+1]='canon-mode'; return true end
 } end
 get_buildinfo=function() return {platform='ixus65_sd630',platsub='100a',build_number='test'} end
 get_prop=function(id) if id==11 then return focus_range elseif id==193 then return aflock elseif id==67 then return (half and not fail_focus) and 1 or 0 else return 0 end end; get_zoom=function() return 0 end
 get_focus=function() return 1000 end; get_mode=function() return mode~=0 end
 get_vbatt=function() return 3800 end; get_config_value=function(id) return id==2100 and 4200 or 3400 end
 set_aflock=function(value) aflock=value and 1 or 0 end
 click=function(key)
  assert(key=='left'); calls[#calls+1]='range-button'
  if not block_range then focus_range=({[0]=1,[1]=3,[3]=0})[focus_range] end
 end
 get_tick_count=function() return ticks end
 get_shooting=function() return half end
 press=function(key) assert(key=='shoot_half'); half=true; calls[#calls+1]='half-press' end
 release=function(key) assert(key=='shoot_half'); half=false; calls[#calls+1]='half-release' end
 sleep=function(ms) ticks=ticks+ms end
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
      execwait=function(_,code) return assert(load(code))() end,
      live_is_api_compatible=function() return true end}
 local responses={}
 print=function(value) responses[#responses+1]=value end
 io.lines=function() local n=0; return function()
  n=n+1
  if physical_wake and n==2 then mode=2; lcd=1; calls[#calls+1]='canon-wake' end
  return lines[n]
 end end
 assert(loadfile(bridge_path))().worker()
 print=original_print; io.lines=original_lines
 return table.concat(calls,','),lcd,connects,responses
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
assert(responses[1]:match('"ok":false') and calls:match('half%-release'),responses[1])
original_print('PASS: focus now uses half-press only, locks on success and releases on timeout')
