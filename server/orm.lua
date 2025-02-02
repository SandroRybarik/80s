local mysql = require("server.mysql")

--- @alias ormentity {[string]: ormfield}

--- @class ormfield
--- @field field string
--- @field type ormtype

--- @alias ormcount fun(...): fun(on_resolved: fun(result: integer|nil, error: string|nil))
--- @alias ormone fun(...): fun(on_resolved: fun(result: table|nil, error: string|nil))
--- @alias ormall fun(...): fun(on_resolved: fun(result: table[]|nil, error: string|nil))
--- @alias ormsave fun(...): fun(on_resolved: fun(result: mysqlerror|mysqlok|mysqleof))
--- @alias ormrepo {all: {[string]: ormall}, one: {[string]: ormone}, count: {[string]: ormcount}, entity: ormentity, source: string, save: ormsave}

--- @class ormtype
local ormtype = {
    format = function()
        return "%s"
    end,
    fromstring = function(text)
        return text
    end,
    toformat = function(value)
        return tostring(value)
    end
}

--- @type {[string]: ormtype}
local ormtypes = {
    text = {
        format = function() return "%s" end,
        fromstring = function(text) return text end,
        toformat = function(value) return tostring(value) end
    },
    int = {
        format = function() return "%d" end,
        fromstring = function(text) return tonumber(text) end,
        toformat = function(value) return tonumber(value) end
    },
    float = {
        format = function() return "%f" end,
        fromstring = function(text) return tonumber(text) end,
        toformat = function(value) return tonumber(value) end
    },
    boolbit = {
        format = function() return "%c" end,
        fromstring = function(text) return text:byte(1, 1) ~= 0 end,
        toformat = function(value) return string.char(value and 1 or 0) end
    },
    ---@diagnostic disable-next-line: assign-type-mismatch
    varchar = function(size)
        return {
            format = function() return "%s" end,
            fromstring = function(text) return text end,
            toformat = function(text)
                if #text > size then return text:sub(1, size) end
                return text
            end
        }
    end,
    datetime = {
        format = function() return "%s" end,
        fromstring = function(text)
            local Y,M,D,H,I,s = text:match("^(%d-)%-(%d-)%-(%d-) (%d-):(%d-):(%d-)")
            if Y and M and D and H and I and s then
                return {
                    year = tonumber(Y),
                    month = tonumber(M),
                    day = tonumber(D),
                    hour = tonumber(H),
                    min = tonumber(M),
                    sec = tonumber(s)
                }
            end
            return nil
        end,
        toformat = function(value)
            if type(value) == "string" then
                return value
            end
            if type(value) ~= "table" then
                value = os.date("*t")
            end
            return string.format("%04d-%02d-%02d %02d:%02d:%02d.%03d", value.year, value.month, value.day, value.hour, value.min, value.sec, 0)
        end
    }
}


local orm = {
    t = ormtypes
}

--- Create repository
---@param sql mysql
---@param repo {source: string, entity:ormentity, [string]: any}
---@return ormrepo
function orm:create(sql, repo)
    --- @type string
    local source = repo.source
    --- @type ormentity
    local entity = repo.entity
    local insert_fields = {}
    local insert_order = {}

    -- construct lookup table for entity decoders
    --- @type {[string]: {dest: string, decode: fun(string): any}}
    local decoders = {}
    for field, def in pairs(entity) do
        if type(def) == "table" then
            decoders[def.field] = {dest = field, decode = def.type.fromstring}
            table.insert(insert_fields, def.field)
            table.insert(insert_order, field)
        end
    end

    local insert_base_query = string.format("INSERT INTO %s (%s) VALUES ", source, table.concat(insert_fields, ","))
    
    repo.sql = sql
    repo.one = {}
    repo.all = {}
    repo.count = {}

    repo.save = function(self, ...)
        local tuples = {}
        for i, item in ipairs({...}) do
            local values = {}
            for j, key in ipairs(insert_order) do
                local value = item[key]
                local def = entity[key]
                if def == nil then
                    print("orm.repo(" .. source .. ").save: missing entity definition for " .. key .. ", using NULL for insert")
                    value = "NULL"
                elseif value == nil then
                    value = "NULL"
                else
                    value = string.format("'%s'", sql:escape(def.type.format():format(def.type.toformat(value))))
                end
                table.insert(values, value)
            end
            table.insert(tuples, string.format("(%s)", table.concat(values, ",")))
        end
        local final_query = string.format("%s %s", insert_base_query, table.concat(tuples, ","))
        return sql:exec(final_query)
    end

    for method, params in pairs(repo) do
        if method:match("^find.*") then
            local token = method
            local args = {}
            --- @type ormtype[]
            local types = {}
            local query = "SELECT * FROM " .. source

            -- first, recognize whether we want to return single entity or all entities
            token = token:gsub("^find", "")

            -- then check for any WHERE filters, assume they are all AND
            if token:match("^By") then
                local attempts = 0
                -- try for 10x to match any of possible fields defined in ormentity as the
                -- starting substring of current token
                while attempts < 10 and #token > 2 do
                    for field, def in pairs(entity) do
                        if type(def) == "table" then
                            -- isolate text after By... and convert first letter to lower case
                            local sub = token:sub(3, 3 + #field)
                            sub = sub:sub(1, 1):lower() .. sub:sub(2)
                            -- if we found a match, insert it to list or arguments
                            if sub == field then
                                table.insert(args, def.field .. " = '" .. def.type.format() .. "'")
                                table.insert(types, def.type)
                                token = token:sub(3 + #field + 1)
                                break
                            end
                        end
                    end
                    attempts = attempts + 1
                end
                query = query
                if #args > 0 then
                    query = query .. " WHERE " .. table.concat(args, " AND ")
                end
            end

            -- finally create the method for repository
            method = method:gsub("findB", "b")
            repo.all[method] = self:create_method(sql, query, types, decoders, false, false, repo.all)
            repo.one[method] = self:create_method(sql, query, types, decoders, true, false, repo.one)
            repo.count[method] = self:create_method(sql, query:gsub("^SELECT %*", "SELECT COUNT(*) AS c"), types, decoders, true, true, repo.count)
        end
    end

    ---@diagnostic disable-next-line: return-type-mismatch
    return repo
end

---Create new ORM method for repository
---@param sql mysql
---@param query string
---@param types ormtype[]
---@param decoders {[string]: {dest: string, decode: fun(string): any}}
---@param single boolean
---@param count boolean
---@param parent table
---@return ormone|ormall|ormcount
function orm:create_method(sql, query, types, decoders, single, count, parent)
    return function(...)
        local treated = {}
        local extras = {}
        local real_i = 1
        local has_limit = false
        local on_resolved, resolver = aio:prepare_promise()
        for i, v in pairs({...}) do
            -- do this so if it is called as :method, it still works
            local special = false
            if type(v) == "table" and v.orderBy then
                table.insert(extras, "ORDER BY " .. v.orderBy)
                special = true
            end
            if type(v) == "table" and v.limit then
                table.insert(extras, "LIMIT " .. v.limit)
                has_limit = true
                special = true
            end
            if not special then
                if i ~= 1 or v ~= parent then
                    table.insert(treated, types[real_i].toformat(v))
                    real_i = real_i + 1
                end
            end
        end
        if single and not has_limit then
            table.insert(extras, "LIMIT 1")
        end
        local final_query = string.format("%s %s", query, table.concat(extras, " "))
        sql:select(final_query, unpack(treated))(function (rows, errorOrColumns)
            -- this function returns either (nil, str_error)
            -- or (nil, nil) for single result that has not been found
            -- or (obj) for single result that has been found
            -- or (obj[]) for multi-result
            if not rows then
                on_resolved(nil, errorOrColumns)
            else
                local results = {}
                for _, row in ipairs(rows) do
                    -- in case of count, directly create the object only with count
                    if count then
                        table.insert(results, {c = tonumber(row.c)})
                        break
                    else
                        -- otherwise remap from raw field names to nice field names defined by entity
                        local obj = {}
                        for key, value in pairs(row) do
                            local field = decoders[key]
                            if not field then
                                obj[key] = value
                            else
                                obj[field.dest] = field.decode(value)
                            end
                        end
                        table.insert(results, obj)
                        if single then
                            break
                        end
                    end
                end
                if single then
                    local result = nil
                    if #results == 1 then result = results[1] end
                    if count then result = result.c end
                    on_resolved(result, nil)
                else
                    on_resolved(results)
                end
            end
        end)
        return resolver
    end
end

return orm