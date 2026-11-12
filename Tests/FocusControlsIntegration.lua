-- No full-shutter operation is used by this test.
local bridge=require'ixus_bridge'
io.stdout:setvbuf('no')
local directory=assert(os.getenv('IXUS_TEST_OUTPUT_DIR'),'Missing test output directory')
local initial,remembered,p_baseline
local modified=false
local request=0
local function snapshot()
 return con:execwait([[local c=require'capmode'; local p=require'propcase'; return {
  mode=c.get(),name=c.get_name(),record=get_mode(),flash=get_prop(p.FLASH_MODE),zoom=get_zoom(),
  aflock=get_prop(p.AF_LOCK),focus=get_focus(),range=get_prop(p.REAL_FOCUS_MODE),battery=get_vbatt(),
  iso=get_prop(p.ISO_MODE),wb=get_prop(p.WB_MODE or 5),ev=get_prop(p.EV_CORRECTION_1),ev2=get_prop(p.EV_CORRECTION_2),metering=get_prop(p.METERING_MODE),count=get_exp_count()
 }]],{timeout=10000})
end
local function run(action,value,output)
 request=request+1
 local previous=print
 local line
 print=function(value) line=tostring(value); previous(value) end
 bridge.run(action,value,output,request)
 print=previous
 assert(line and line:find('"ok":true',1,true),line or 'Missing bridge reply')
 if action=='focusnow' then assert(line:find('"focusSucceeded":true',1,true),'Camera did not confirm focus') end
 return line
end
local function image(name)
 local path=directory..'/'..name..'.ppm'
 local line=run('frame',nil,path)
 assert(line:find('"overlay":',1,true),'Missing bitmap overlay')
 local f=assert(io.open(path..'.rgba','rb')); local data=f:read('*a'); f:close()
 local width,height,body=data:match('^RGBA\n(%d+) (%d+)\n(.*)$')
 assert(width and #body==tonumber(width)*tonumber(height)*4,'Malformed screen overlay')
 local visible=0
 for i=4,#body,4 do if body:byte(i)>0 then visible=visible+1 end end
 assert(visible>0,'No visible menu pixels')
 print(('PASS: %s bitmap %sx%s, %d nontransparent pixels'):format(name,width,height,visible))
end
local function restore_props(s)
 con:execwait(([[local p=require'propcase'; set_prop(p.FLASH_MODE,%d); set_zoom(%d);
  set_prop(p.ISO_MODE,%d); set_prop(p.WB_MODE or 5,%d); set_prop(p.EV_CORRECTION_1,%d);set_prop(p.EV_CORRECTION_2,%d);set_prop(p.METERING_MODE,%d);
  set_aflock(%s); sleep(300)]]):format(s.flash,s.zoom,s.iso,s.wb,s.ev,s.ev2,s.metering,s.aflock==1 and 'true' or 'false'))
end
local function restore()
 if not initial or not modified then return end
 if not con:is_connected() then run('status') end
 run('record')
 -- A short half-press exits either Canon menu without taking a photograph.
 run('screen',0)
 if p_baseline then
  run('mode',2)
  local now=snapshot()
  if now.range~=p_baseline.range and (p_baseline.range==0 or p_baseline.range==1 or p_baseline.range==3) then run('focusrange',p_baseline.range) end
  restore_props(p_baseline)
 end
 if remembered then
  run('mode',remembered.mode)
  if snapshot().range~=remembered.range then run('focusrange',remembered.range) end
  restore_props(remembered)
  if remembered.aflock==1 then
   con:execwait(('set_aflock(true); set_focus(%d); sleep(300)'):format(remembered.focus))
  end
 end
 if not initial.record then run('play') end
 run('display',1)
 local final=snapshot()
 for _,key in ipairs({'mode','record','flash','zoom','aflock','range','iso','wb','ev','ev2','metering','count'}) do
  assert(final[key]==initial[key],('Restore mismatch %s: %s vs %s'):format(key,tostring(final[key]),tostring(initial[key])))
 end
 print('PASS: initial mode, playback/record, flash, zoom, AF lock, exposure/color properties and exposure counter restored')
end
local ok,err=xpcall(function()
 run('status')
 initial=snapshot()
 print('INITIAL: '..util.serialize(initial))
 assert(initial.battery>=3650,'Recharge the battery before the hardware test')
 if initial.record then assert(initial.mode==1 or initial.mode==2 or initial.mode==36,'Select Auto, P or Portrait before this test') end
 modified=true
 run('record'); remembered=snapshot()
 if remembered.mode~=1 and remembered.mode~=2 and remembered.mode~=36 then
  if not initial.record then run('play') end
  modified=false
  error('Select Auto, P or Portrait before this test')
 end
 run('mode',2); p_baseline=snapshot(); run('zoom',0)
 sys.sleep(800)
 for _,range in ipairs({1,3,p_baseline.range}) do run('focusrange',range); assert(snapshot().range==range,'Focus range not applied') end
 print('PASS: macro, infinity and initial focus range read back')
 run('focusrange',1)
 sys.sleep(600)
 run('focusnow',0)
 local focused=snapshot()
 assert(focused.aflock==0,'Unexpected AF Lock after focus-only operation')
 run('focuslock',1)
 local locked=snapshot()
 assert(locked.aflock==1,'AF Lock not enabled')
 print(('PASS: autofocus and autofocus+lock, reported focus %d mm; optical sharpness requires observation'):format(locked.focus))
 assert(locked.count==initial.count,'Exposure counter changed')
 restore()
end,debug.traceback)
if not ok then
 print('FAIL: '..tostring(err))
 local restored,restore_err=pcall(restore)
 if not restored then print('RESTORE FAILED: '..tostring(restore_err)) end
end
if con:is_connected() then
 pcall(function() con:execwait("release('shoot_half'); set_backlight(1)") end)
 con:disconnect()
end
print(ok and 'DONE: no photographs taken; backlight ON requested' or 'TEST FAILED')
if not ok then os.exit(1) end
