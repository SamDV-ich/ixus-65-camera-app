package.path='Resources/?.lua;'..package.path
local capture=require'ixus_capture'
local directory=os.tmpname(); os.remove(directory); assert(os.execute('mkdir '..directory))
local paths={}; local shots=0; local removed={}; local fail_download=false; local fail_delete=false; local reject_property=false
local props={}
package.preload.propcase=function() return {QUALITY=23,RESOLUTION=24} end
local info
local camera={}
function camera:execwait(code,opts)
 local env={require=require,assert=assert,type=type,get_raw=function() return 0 end,set_raw=function() end,
  set_prop=function(id,v) if not reject_property then props[id]=v end end,get_prop=function(id) return props[id] end,
  rlib_shoot=function(options)
   shots=shots+1
   info={dir='A/DCIM/100CANON',exp=6202,raw=options.raw==1,dng=options.dng==1,raw_dir_opt=1,raw_pfx=1,raw_ext=1,use_dng_ext=true}
   paths={['A/DCIM/100CANON/IMG_6202.JPG']={size=10,mtime=100}}
   if info.raw then paths['A/DCIM/100CANON/CRW_6202.'..(info.dng and 'DNG' or 'CRW')]={size=20,mtime=100} end
   return info
  end,
  get_tick_count=function() return 0 end,sleep=function() end,os={stat=function(path) return paths[path] end}}
 return assert(load(code,nil,'t',env))()
end
function camera:download(path,dest)
 if fail_download then error('I/O error',0) end
 local f=assert(io.open(dest,'wb')); f:write(string.rep('a',paths[path].size)); f:close()
end
function camera:script_status() return {run=false} end
function camera:stat(path) return paths[path] end
function camera:remove(path)
 if fail_delete then return false,'delete failed' end
 removed[#removed+1]=path; paths[path]=nil; return true
end
local function clean()
 os.remove(directory..'/IMG_6202.JPG'); os.remove(directory..'/CRW_6202.CRW'); os.remove(directory..'/CRW_6202.DNG')
end
local ok,err=pcall(function()
 local result=capture.take(camera,10,nil)
 assert(not result.capturedFiles and #result.cameraFiles==1 and #removed==0)
 assert(not pcall(capture.finish,camera),'Camera-only created deletion transaction')
 result=capture.take(camera,0,directory)
 assert(result.capturedFiles[1].size==10 and #removed==0)
 assert(not pcall(capture.finish,camera),'Both created deletion transaction')
 result=capture.take(camera,5322,directory)
 assert(props[23]==2 and props[24]==4 and #result.capturedFiles==2 and result.capturedFiles[2].kind=='dng')
 assert(#removed==0,'Deleted before local verification')
 fail_delete=true
 assert(not capture.finish(camera).deleted and #removed==0)
 fail_delete=false
 assert(capture.finish(camera).deleted and #removed==2)
 assert(not pcall(capture.finish,camera),'Repeated delete allowed')
 result=capture.take(camera,21,directory)
 assert(result.capturedFiles[2].kind=='raw')
 paths[result.cameraFiles[1]].mtime=101
 result=capture.finish(camera)
 assert(not result.deleted and paths['A/DCIM/100CANON/IMG_6202.JPG'],'Changed original was deleted')
 fail_download=true
 assert(not pcall(capture.take,camera,20,directory))
 assert(not pcall(capture.finish,camera),'Failed download left deletion enabled')
 local failed=capture.attempt(camera,20,directory)
 assert(failed.captureFailed and failed.shotRequested and failed.captureError:find('Скачивание с камеры:',1,true) and failed.captureError:find('I/O error',1,true))
 local original_status=camera.script_status
 camera.script_status=function() error('I/O error',0) end
 local success,message=pcall(capture.attempt,camera,20,directory)
 assert(not success and tostring(message):find('Скачивание с камеры:',1,true))
 camera.script_status=original_status
 fail_download=false; reject_property=true
 local before=shots
 assert(not pcall(capture.take,camera,100,directory))
 assert(shots==before,'Property refusal still took a shot')
 local rejected=capture.attempt(camera,100,directory)
 assert(rejected.captureFailed and not rejected.shotRequested and rejected.captureError:find('Применение качества',1,true))
 print('PASS: JPEG/RAW/DNG routing, property readback, no premature deletion, failed download retention and changed-file protection')
end)
clean(); os.remove(directory)
assert(ok,err)
