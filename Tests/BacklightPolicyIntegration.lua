local bridge=require('ixus_bridge')
io.stdout:setvbuf('no')
local request=0
local function run(action,value)
 request=request+1
 local previous=print
 local result
 print=function(line) result=tostring(line); previous(line) end
 bridge.run(action,value,nil,request)
 print=previous
 assert(result and result:find('"ok":true',1,true),result or 'No response')
 return result
end
local function state()
 return con:execwait([[local c=require'capmode'; local p=require'propcase'; return {mode=c.get(),record=get_mode(),flash=get_prop(p.FLASH_MODE),zoom=get_zoom(),aflock=get_prop(p.AF_LOCK)}]])
end
local initial,shooting
local function restore()
 if not initial or not con:is_connected() then return end
 run('record')
 if shooting then run('mode',shooting.mode) end
 run('flash',initial.flash)
 run('zoom',initial.zoom)
 con:execwait(('set_aflock(%s); sleep(100)'):format(initial.aflock==1 and 'true' or 'false'))
 if not initial.record then run('play') end
 run('display',1)
 local final=state()
 assert(final.mode==initial.mode and final.record==initial.record and final.flash==initial.flash and final.zoom==initial.zoom and final.aflock==initial.aflock,'Baseline not restored')
 print('PASS: mode, record/play, flash, zoom, AF lock restored; backlight ON requested')
end
local ok,err=xpcall(function()
 run('status')
 initial=state()
 print(('BASELINE: mode=%d record=%s flash=%d zoom=%d aflock=%d'):format(initial.mode,tostring(initial.record),initial.flash,initial.zoom,initial.aflock))
 if initial.record then assert(initial.mode==1 or initial.mode==2 or initial.mode==36,'Initial capture mode not in verified profile') end
 run('record'); shooting=state()
 assert(shooting.mode==1 or shooting.mode==2 or shooting.mode==36,'Remembered capture mode not in verified profile')
 run('display',0)
 run('mode',shooting.mode==2 and 1 or 2)
 print('MODE_CHANGED: keep-off applied after app command')
 -- Emulate the camera waking its lamp outside the application policy.
 con:execwait('set_backlight(1); sleep(150)')
 sys.sleep(1000)
 local reply=run('poll')
 assert(reply:find('"keepBacklightOff":true',1,true),'Keep-off policy lost')
 print('OBSERVE_NOW: backlight should be dark after external wake; polling for 12 seconds')
 for i=1,12 do sys.sleep(1000); run('poll') end
 run('play'); run('poll')
 run('record'); run('poll')
 print('PASS: Auto/P and play/record transitions, repeated polls, same USB connection')
 restore()
end,debug.traceback)
if not ok then
 print('FAIL: '..tostring(err))
 local restored,restore_err=pcall(restore)
 if not restored then print('RESTORE FAILED: '..tostring(restore_err)) end
end
if con:is_connected() then
 pcall(function() con:execwait('set_backlight(1); sleep(200)') end)
 con:disconnect()
end
print(ok and 'DONE: no photographs taken; please confirm visible screen restored' or 'TEST FAILED')

if not ok then os.exit(1) end
