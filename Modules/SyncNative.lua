-- Data-only wire codec for the isolated native transport.
local _, GP = ...
local N = {}
GP.SyncNative = N
local DEPTH, NODES = 32, 200000
function N:Available()
    local a=C_EncodingUtil
    return a and type(a.CompressString)=="function" and type(a.DecompressString)=="function"
        and type(a.EncodeBase64)=="function" and type(a.DecodeBase64)=="function"
        and C_ChatInfo and type(C_ChatInfo.SendAddonMessage)=="function"
        and Enum and Enum.CompressionMethod and Enum.CompressionMethod.Deflate~=nil
        and Enum.Base64Variant and Enum.Base64Variant.StandardUrlSafe~=nil
        and Enum.SendAddonMessageResult and Enum.SendAddonMessageResult.Success~=nil
end
function N:Encode(value)
    local nodes,seen=0,{}
    local function encode(v,depth)
        nodes=nodes+1;assert(depth<=DEPTH and nodes<=NODES,"complexity")
        local kind=type(v)
        if kind=="string" then
            local hex=v:gsub(".",function(c) return string.format("%02x",c:byte()) end)
            return "s"..#hex..":"..hex
        elseif kind=="number" then
            assert(v==v and v~=math.huge and v~=-math.huge,"number")
            local s=string.format("%.17g",v);return "n"..#s..":"..s
        elseif kind=="boolean" then return v and "y" or "z"
        elseif kind=="table" then
            assert(not seen[v] and not getmetatable(v),"table");seen[v]=true
            local keys={}
            for k in pairs(v) do
                assert(type(k)=="string" or type(k)=="number","key");keys[#keys+1]=k
                assert(#keys<=NODES,"entries")
            end
            table.sort(keys,function(a,b) if type(a)==type(b) then return a<b end;return type(a)<type(b) end)
            local out={"t"..#keys..":"}
            for _,k in ipairs(keys) do out[#out+1]=encode(k,depth+1);out[#out+1]=encode(v[k],depth+1) end
            seen[v]=nil;return table.concat(out)
        end
        error("type")
    end
    local ok,text=pcall(encode,value,0)
    if ok then return text end
    return nil,"Native codec rejected data"
end
function N:Decode(text)
    if type(text)~="string" then return false end
    local pos,nodes=1,0
    local function read(depth)
        nodes=nodes+1;assert(depth<=DEPTH and nodes<=NODES,"complexity")
        local tag=text:sub(pos,pos);pos=pos+1
        if tag=="y" then return true elseif tag=="z" then return false end
        assert(tag=="s" or tag=="n" or tag=="t","tag")
        local stop=text:find(":",pos,true);assert(stop and stop-pos<=12,"length")
        local raw=text:sub(pos,stop-1);assert(raw:match("^%d+$"),"length")
        local length=tonumber(raw);assert(length<=#text,"length");pos=stop+1
        if tag=="t" then
            assert(length<=NODES,"entries");local out={}
            for _=1,length do
                local k=read(depth+1);assert(type(k)=="string" or type(k)=="number","key")
                assert(out[k]==nil,"duplicate");out[k]=read(depth+1)
            end
            return out
        end
        assert(pos+length-1<=#text,"truncated")
        local v=text:sub(pos,pos+length-1);pos=pos+length
        if tag=="n" then
            v=tonumber(v);assert(v and v==v and v~=math.huge and v~=-math.huge,"number");return v
        end
        assert(#v%2==0 and not v:find("[^%x]"),"hex")
        return (v:gsub("..",function(c) return string.char(tonumber(c,16)) end))
    end
    local ok,result=pcall(read,0)
    if not ok or pos~=#text+1 then return false end
    return true,result
end
function N:Pack(text)
    local a=C_EncodingUtil
    local ok,compressed=pcall(a.CompressString,text,Enum.CompressionMethod.Deflate)
    if not ok or type(compressed)~="string" then return text end
    local encoded
    ok,encoded=pcall(a.EncodeBase64,compressed,Enum.Base64Variant.StandardUrlSafe)
    if not ok or type(encoded)~="string" or not encoded:match("^[%w_%-=]+$") then return text end
    local packed="N:"..#text..":"..encoded
    return #packed<#text and packed or text
end
function N:Unpack(text,limit)
    if text:sub(1,2)~="N:" then return text end
    local size,encoded=text:match("^N:(%d+):([%w_%-=]+)$")
    size=tonumber(size)
    if not size or size<1 or size>limit then return nil end
    local a=C_EncodingUtil
    local ok,compressed=pcall(a.DecodeBase64,encoded,Enum.Base64Variant.StandardUrlSafe)
    if not ok or type(compressed)~="string" then return nil end
    local plain
    ok,plain=pcall(a.DecompressString,compressed,Enum.CompressionMethod.Deflate)
    if not ok or type(plain)~="string" or #plain~=size then return nil end
    return plain
end
