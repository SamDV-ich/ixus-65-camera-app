-- Canon IXUS 65 photo controls. Unknown modes expose no speculative controls.
local M={}
local function base_controls(name)
 name=(name or ''):gsub('^SCN_','')
 if name=='AUTO' then return {flash={0,2},focusrange={0,1},zoom={0,1,2,3,4,5,6}} end
 if name=='P' or name=='LONG_SHUTTER' then
  return {flash={0,1,2},focusrange={0,1,3},zoom={0,1,2,3,4,5,6},focuslock={0,1},focus={1}}
 end
 if name=='DIGITAL_MACRO' then return {focuslock={0,1},focus={1}} end
 if name=='FIREWORK' or name=='FIREWORKS' then return {zoom={0,1,2,3,4,5,6}} end
 local scene={PORTRAIT=true,NIGHT_SNAPSHOT=true,KIDS_PETS=true,INDOOR=true,FOLIAGE=true,SNOW=true,BEACH=true,UNDERWATER=true,COLOR_ACCENT=true,COLOR_SWAP=true,STITCH=true}
 if scene[name] then
  local controls={flash={0,1,2},zoom={0,1,2,3,4,5,6}}
  if name=='COLOR_ACCENT' or name=='COLOR_SWAP' or name=='STITCH' then controls.flash={1,2} end
  if name~='KIDS_PETS' then controls.focusrange={0,1,3} end
  return controls
 end
 return {}
end
function M.controls(name)
 local controls=base_controls(name)
 name=(name or ''):gsub('^SCN_','')
 local manual=name=='P' or name=='LONG_SHUTTER'
 if name=='AUTO' then controls.iso={0,1} end
 if manual or name=='DIGITAL_MACRO' then
  controls.iso={0,1,80,100,200,400,800}
  controls.wb={0,1,2,3,4,5,7}
  controls.metering={0,1,2}
 end
 if manual or name=='DIGITAL_MACRO' or name=='PORTRAIT' or name=='NIGHT_SNAPSHOT' or name=='KIDS_PETS' or name=='INDOOR' or name=='FOLIAGE' or name=='SNOW' or name=='BEACH' or name=='UNDERWATER' or name=='FIREWORK' then
  controls.ev={}; for value=-192,192,32 do controls.ev[#controls.ev+1]=value end
 end
 return controls
end
function M.allows(controls,key,value)
 for _,v in ipairs(controls[key] or {}) do if v==value then return true end end
 return false
end
return M
