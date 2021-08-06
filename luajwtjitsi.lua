local cjson  = require 'cjson'
local base64 = require 'base64'
local digest = require 'openssl.digest'
local hmac   = require 'openssl.hmac'
local pkey   = require 'openssl.pkey'

local function signRS (data, key, algo)
	local privkey = pkey.new(key)
	if privkey == nil then
		return nil, 'Not a private PEM key'
	else
		local datadigest = digest.new(algo):update(data)
		return privkey:sign(datadigest)
	end
end

local function verifyRS (data, signature, key, algo)
	local pubkey = pkey.new(key)
	if pubkey == nil then
		return nil, 'Not a public PEM key'
	else
		local datadigest = digest.new(algo):update(data)
		return pubkey:verify(signature, datadigest)
	end
end

local alg_sign = {
	['HS256'] = function(data, key) return hmac.new(key, 'sha256'):final(data) end,
	['HS384'] = function(data, key) return hmac.new(key, 'sha384'):final(data) end,
	['HS512'] = function(data, key) return hmac.new(key, 'sha512'):final(data) end,
	['RS256'] = function(data, key) return signRS(data, key, 'sha256') end,
	['RS384'] = function(data, key) return signRS(data, key, 'sha384') end,
	['RS512'] = function(data, key) return signRS(data, key, 'sha512') end
}

local alg_verify = {
	['HS256'] = function(data, signature, key) return signature == alg_sign['HS256'](data, key) end,
	['HS384'] = function(data, signature, key) return signature == alg_sign['HS384'](data, key) end,
	['HS512'] = function(data, signature, key) return signature == alg_sign['HS512'](data, key) end,
	['RS256'] = function(data, signature, key) return verifyRS(data, signature, key, 'sha256') end,
	['RS384'] = function(data, signature, key) return verifyRS(data, signature, key, 'sha384') end,
	['RS512'] = function(data, signature, key) return verifyRS(data, signature, key, 'sha512') end
}

local function b64_encode(input)
	local result = base64.encode(input)

	result = result:gsub('+','-'):gsub('/','_'):gsub('=','')

	return result
end

local function b64_decode(input)
--	input = input:gsub('\n', ''):gsub(' ', '')

	local reminder = #input % 4

	if reminder > 0 then
		local padlen = 4 - reminder
		input = input .. string.rep('=', padlen)
	end

	input = input:gsub('-','+'):gsub('_','/')

	return base64.decode(input)
end

local function tokenize(str, div, len)
	local result, pos = {}, 0

	for st, sp in function() return str:find(div, pos, true) end do

		result[#result + 1] = str:sub(pos, st-1)
		pos = sp + 1

		len = len - 1

		if len <= 1 then
			break
		end
	end

	result[#result + 1] = str:sub(pos)

	return result
end

local M = {}

function M.encode(data, key, alg, header)
	if type(data) ~= 'table' then return nil, "Argument #1 must be table" end
	if type(key) ~= 'string' then return nil, "Argument #2 must be string" end

	alg = alg or "HS256"

	if not alg_sign[alg] then
		return nil, "Algorithm not supported"
	end

	header = header or {}

	header['typ'] = 'JWT'
	header['alg'] = alg

	local segments = {
		b64_encode(cjson.encode(header)),
		b64_encode(cjson.encode(data))
	}

	local signing_input = table.concat(segments, ".")
	local signature, error = alg_sign[alg](signing_input, key)
	if signature == nil then
		return nil, error
	end

	segments[#segments+1] = b64_encode(signature)

	return table.concat(segments, ".")
end

-- Verify that the token is valid, and if it is return the decoded JSON payload data.
function M.verify(data, algo, key)
	if type(data) ~= 'string' then return nil, "data argument must be string" end
	if type(algo) ~= 'string' then return nil, "algorithm argument must be string" end
	if type(key) ~= 'string' then return nil, "key argument must be string" end

	if not alg_verify[algo] then
		return nil, "Algorithm not supported"
	end

	local token = tokenize(data, '.', 3)
	if #token ~= 3 then
		return nil, "Invalid token"
	end

	local headerb64, bodyb64, sigb64 = token[1], token[2], token[3]

	local ok, header, body, sig = pcall(function ()
		return	cjson.decode(b64_decode(headerb64)),
			cjson.decode(b64_decode(bodyb64)),
			b64_decode(sigb64)
	end)

	if not ok then
		return nil, "Invalid json"
	end

	-- Only validate typ if present
	if header.typ and header.typ ~= "JWT" then
		return nil, "Invalid typ"
	end

	if not header.alg or header.alg ~= algo then
		return nil, "Invalid or incorrect alg"
	end

	if body.exp and type(body.exp) ~= "number" then
		return nil, "exp must be number"
	end

	if body.nbf and type(body.nbf) ~= "number" then
		return nil, "nbf must be number"
	end

	local verify_result, err
		= alg_verify[algo](headerb64 .. "." .. bodyb64, sig, key);
	if verify_result == nil then
		return nil, err
	elseif verify_result == false then
		return nil, "Invalid signature"
	end

	if body.exp and os.time() >= body.exp then
		return nil, "Not acceptable by exp"
	end

	if body.nbf and os.time() < body.nbf then
		return nil, "Not acceptable by nbf"
	end

	return body
end

-- Warning - this is not secure if using a public key, since client could use the public key to sign
-- a fake token with an HMAC algo and set that as the 'alg' to use in the header. Use M.verify above
-- instead if using public key verification, so that you can choose the alg, not the client.
function M.decode(data, key, verify)
	if key and verify == nil then verify = true end
	if type(data) ~= 'string' then return nil, "Argument #1 must be string" end
	if verify and type(key) ~= 'string' then return nil, "Argument #2 must be string" end

	local token = tokenize(data, '.', 3)

	if #token ~= 3 then
		return nil, "Invalid token"
	end

	local headerb64, bodyb64, sigb64 = token[1], token[2], token[3]

	local ok, header, body, sig = pcall(function ()

		return	cjson.decode(b64_decode(headerb64)),
			cjson.decode(b64_decode(bodyb64)),
			b64_decode(sigb64)
	end)

	if not ok then
		return nil, "Invalid json"
	end

	if verify then

		-- Only validate typ if present
		if header.typ and header.typ ~= "JWT" then
			return nil, "Invalid typ"
		end

		if not header.alg or type(header.alg) ~= "string" then
			return nil, "Invalid alg"
		end

		if body.exp and type(body.exp) ~= "number" then
			return nil, "exp must be number"
		end

		if body.nbf and type(body.nbf) ~= "number" then
			return nil, "nbf must be number"
		end

		if not alg_verify[header.alg] then
			return nil, "Algorithm not supported"
		end

		local verify_result, error
			= alg_verify[header.alg](headerb64 .. "." .. bodyb64, sig, key);
		if verify_result == nil then
			return nil, error
		elseif verify_result == false then
			return nil, "Invalid signature"
		end

		if body.exp and os.time() >= body.exp then
			return nil, "Not acceptable by exp"
		end

		if body.nbf and os.time() < body.nbf then
			return nil, "Not acceptable by nbf"
		end
	end

	return body
end

return M
