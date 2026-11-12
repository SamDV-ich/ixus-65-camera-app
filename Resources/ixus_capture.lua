-- One explicit shot transaction. Only paths reported by that shot can be deleted.
local M={}
local pending
local function checked_path(path)
 assert(type(path)=='string' and path:match('^A/[A-Za-z0-9_/.]+$') and not path:find('..',1,true),'Некорректный путь снимка на камере')
 return path
end
function M.take(con,code,output)
 code=code or 0
 local format=code%10; local destination=math.floor(code/10)%10
 local quality=math.floor(code/100)%10-1; local resolution=math.floor(code/1000)-1
 assert(format>=0 and format<=2 and destination>=0 and destination<=2,'Некорректный формат или назначение')
 assert(quality>=-1 and quality<=2 and (resolution==-1 or resolution==0 or resolution==1 or resolution==2 or resolution==4 or resolution==8),'Некорректное качество или размер')
 assert(destination==1 or (output and output~=''),'Не выбрана папка')
 pending=nil
 -- These property writes and readbacks occur before shoot; refusal cannot take a photo.
 local prepare=([[local p=require'propcase';
 if %d>=0 then assert(p.QUALITY,'Качество недоступно'); set_prop(p.QUALITY,%d); assert(get_prop(p.QUALITY)==%d,'Камера не приняла качество') end;
 if %d>=0 then assert(p.RESOLUTION,'Размер недоступен'); set_prop(p.RESOLUTION,%d); assert(get_prop(p.RESOLUTION)==%d,'Камера не приняла размер') end;
 if %d>0 then assert(type(get_raw)=='function' and type(set_raw)=='function','RAW недоступен'); if type(is_raw_possible)=='function' then assert(is_raw_possible(),'RAW недоступен в этом режиме') end end
 ]]):format(quality,quality,quality,resolution,resolution,resolution,format)
 con:execwait(prepare)
 local info,err=con:execwait(('return rlib_shoot({info=true,raw=%d,dng=%d})'):format(format>0 and 1 or 0,format==2 and 1 or 0),{libs={'serialize_msgs','rlib_shoot'},timeout=60000})
 assert(type(info)=='table',err or 'Камера не подтвердила снимок; проверьте карту перед повтором')
 assert(type(info.exp)=='number' and info.exp%1==0 and info.exp>=0 and info.exp<=9999,'Некорректный номер снимка')
 local paths={{path=checked_path(('%s/IMG_%04d.JPG'):format(info.dir,info.exp)),kind='jpeg'}}
 if format>0 then
  assert(info.raw,'Камера не сохранила RAW; JPEG оставлен на карте')
  if format==2 then assert(info.dng,'Камера не сохранила DNG; оригиналы оставлены на карте') end
  local directory=info.raw_dir_opt==1 and info.dir or (info.raw_dir_opt==2 and info.dir:gsub('^A/DCIM','A/RAW') or (info.dir:match('^A/DCIM/%d%d%d_') and 'A/DCIM/101___01' or 'A/DCIM/100CANON'))
  local prefix=({[0]='IMG','CRW','SND'})[info.raw_pfx] or 'RAW_'
  local extension=info.dng and info.use_dng_ext and 'DNG' or (({[0]='JPG','CRW','CR2','THM','WAV'})[info.raw_ext] or 'RAW')
  local path=checked_path(('%s/%s_%04d.%s'):format(directory,prefix,info.exp,extension))
  assert(path~=paths[1].path,'RAW и JPEG имеют одинаковый путь; оригиналы оставлены на карте')
  paths[#paths+1]={path=path,kind=format==2 and 'dng' or 'raw'}
 end
 local downloaded={}; local cameraFiles={}
 for i,file in ipairs(paths) do
  cameraFiles[i]=file.path
  local stat=con:execwait(([[local path=%q; local t=get_tick_count(); local s; repeat s=os.stat(path); if not s then sleep(50) end until s or get_tick_count()-t>3000; return s]]):format(file.path))
  assert(stat and stat.size and stat.size>0,'Снимок не найден на карте; проверьте карту перед повтором')
  file.size=stat.size; file.mtime=stat.mtime
  file.name=file.path:match('([^/]+)$')
  if destination~=1 then
   local ok,e=con:download(file.path,output..'/'..file.name); assert(ok,e or 'Ошибка скачивания; оригиналы оставлены на карте')
   local f=assert(io.open(output..'/'..file.name,'rb')); local size=f:seek('end'); f:close()
   assert(size==file.size,'Неполный файл; оригиналы оставлены на карте')
   downloaded[#downloaded+1]={name=file.name,kind=file.kind,size=file.size}
  end
 end
 if destination==2 then pending=paths end
 return {capturedFiles=destination~=1 and downloaded or nil,cameraFiles=cameraFiles}
end
function M.finish(con)
 assert(pending,'Нет подтверждённого снимка для удаления')
 -- The caller invokes this only after all requested local products are durable.
 local remaining={}; local failures={}
 for _,file in ipairs(pending) do
  local status,stat=pcall(function() return con:stat(file.path) end)
  if not status or not stat or stat.size~=file.size or (file.mtime and stat.mtime~=file.mtime) then
   remaining[#remaining+1]=file; failures[#failures+1]=file.path
  else
   local status,ok=pcall(function() return con:remove(file.path) end)
   if not status or not ok then remaining[#remaining+1]=file; failures[#failures+1]=file.path end
  end
 end
 pending=#remaining>0 and remaining or nil
 return {deleted=#failures==0,warning=#failures>0 and ('Файлы на Mac сохранены. Не удалось удалить с камеры: '..table.concat(failures,', ')) or nil}
end
return M
