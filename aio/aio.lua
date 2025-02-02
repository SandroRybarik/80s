--- @class net
--- @field write fun(elfd: lightuserdata, childfd: lightuserdata, data: string, offset: integer): boolean write data to file descriptor
--- @field close fun(elfd: lightuserdata, childfd: lightuserdata): boolean close a file descriptor
--- @field connect fun(elfd: lightuserdata, host: string, port: integer): fd: lightuserdata|nil, err: string|nil open a new network connection
--- @field reload fun() reload server
--- @field listdir fun(dir: string): string[] list files in directory
net = net or {}

--- @class crext
--- @field sha1 fun(data: string): string perform sha1(data), returns bytestring with raw data
--- @field sha256 fun(data: string): string perform sha256(data), returns bytestring with raw data
crext = crext or {}

--- @class jit
jit = jit or nil

--- @type lightuserdata
ELFD = ELFD or nil

--- @type integer
WORKERID = WORKERID or nil

--- Aliases to be defined here
--- @alias aiostream fun() : any ... AIO input stream
--- @alias aiocor fun(stream: aiostream, resolve?: fun(value: any)|thread): nil AIO coroutine
--- @alias aioresolve fun(result: any): nil AIO resolver
--- @alias aiothen fun(on_resolved: fun(...: any)|thread) AIO then
--- @alias aiohttphandler fun(self: aiosocket, query: string, headers: {[string]: string}, body: string) AIO HTTP handler

--- @alias aiowritebuf {d: string, o: integer}

unpack = unpack or table.unpack

--- AIOsocket class
--- Provides easy wrapper to receive events per object instead of globally
---
--- @class aiosocket
local aiosocket = {
    --- @type lightuserdata socket file scriptor
    childfd = nil,
    --- @type lightuserdata event loop file descriptor
    elfd = nil,
    --- @type boolean true if close after write
    cw = false,
    --- @type boolean true if socket is connected
    co = false,
    --- @type boolean true if socket is writeable
    wr = false,
    --- @type aiowritebuf[] buffer
    buf = {},
    --- @type boolean closed
    closed = false,
}

--- Write data to network
---
--- @param data string data to write
--- @param close boolean|nil close after write
--- @return boolean
function aiosocket:write(data, close)
    if self.closed then return false end
    if close ~= nil then self.cw = close end
    if not self.wr then 
        table.insert(self.buf, {d=data, o=0})
        return true
    end
    local to_write = #data
    local ok, written = net.write(self.elfd, self.childfd, data, 0)
    if not ok then
        self:close()
        return false
    elseif written < to_write then
        self.wr = false
        table.insert(self.buf, {d=data, o=written})
        return true
    elseif self.cw then
        self.buf = {}
        self:close()
        return true
    else
        self.buf = {}
        return true
    end
end

--- Close socket
--- @return boolean
function aiosocket:close()
    if self.closed then return true end
    self.buf = {}
    return net.close(self.elfd, self.childfd)
end

--- Write HTTP respose
---@param status string status code
---@param headers {[string]: any}|string headers or content-type
---@param response string response body
---@return boolean
function aiosocket:http_response(status, headers, response)
    if self.closed then return false end
    local str_headers = ""
    if type(headers) == "string" then
        str_headers = "Content-type: " .. headers .. "\r\n"
    else
        for k, v in pairs(headers) do
            str_headers = str_headers .. string.format("%s: %s\r\n", k, v)
        end
    end
    return self:write(
        string.format("HTTP/1.1 %s\r\nConnection: %s\r\n%sContent-length: %d\r\n\r\n%s",
            status,
            self.cw and "close" or "keep-alive",
            str_headers,
            #response, response
        )
    )
end

--- Close handler of socket, overridable
---
--- @param elfd lightuserdata epoll handle
--- @param childfd lightuserdata socket handle
function aiosocket:on_close(elfd, childfd)

end

--- Data handler of socket, overridable
---
--- @param elfd lightuserdata epoll handle
--- @param childfd lightuserdata socket handle
--- @param data string stream data
--- @param length integer length of data
function aiosocket:on_data(elfd, childfd, data, length)

end

--- Connect handler of socket, overridable
---
--- @param elfd lightuserdata epoll handle
--- @param childfd lightuserdata socket handle
function aiosocket:on_connect(elfd, childfd)

end

--- Writeable handler of socket, overridable
---
--- @param elfd lightuserdata epoll handle
--- @param childfd lightuserdata socket handle
function aiosocket:on_write(elfd, childfd)
    -- on connect is called only once
    self.wr = true
    if not self.co then
        self.co = true
        self:on_connect(elfd, childfd)
    end
    if self.closed then return end
    -- keep in mind that on_write is only triggered when socket previously failed to write part of data
    -- if there is any data remaining to be sent, try to send it
    while #self.buf > 0 do
        local item = self.buf[1]
        local to_write = #item.d - item.o
        local ok, written = net.write(elfd, childfd, item.d, item.o)
        if not ok then
            -- if sending failed completly, i.e. socket was closed, end
            self:close()
        elseif written < to_write then
            -- if we were able to send only part of data due to full buffer, equeue it for later
            self.wr = false
            item.o = item.o + written
            break
        elseif self.cw then
            -- if we sent everything and require close after write, close the socket
            self:close()
            break
        else
            table.remove(self.buf, 1)
        end
    end
end

--- Create new socket instance
---
--- @param elfd lightuserdata
--- @param childfd lightuserdata
--- @param connected boolean
--- @return aiosocket
function aiosocket:new(elfd, childfd, connected)
    local socket = { elfd = elfd, childfd = childfd, cw = false, co = connected or false, wr = connected or false }
    setmetatable(socket, self)
    self.__index = self
    return socket
end

if not aio then
    --- AIO object
    --- There can be only one instance of AIO, enabling hot-reloads
    --- as fds won't be lost during the reload
    ---
    --- @class aio
    aio = {
        --- @type {[string]: aiosocket}
        fds={},
        --- @type {[string]: {[string]: aiohttphandler}}
        http={
            --- @type {[string]: aiohttphandler}
            GET={},
            --- @type {[string]: aiohttphandler}
            POST={}
        },
        cors = 0
    }
end

--- Generic handler called when data is received
---
--- @param elfd lightuserdata epoll handle
--- @param childfd lightuserdata socket handle
--- @param data string incoming stream data
--- @param len integer length of data
function aio:on_data(elfd, childfd, data, len)
    local fd = self.fds[childfd]
    if fd ~= nil then
        fd:on_data(elfd, childfd, data, len)
        return
    end

    self:handle_as_http(elfd, childfd, data, len)
end

--- Create new HTTP handler for network stream
---
--- @param elfd lightuserdata epoll handle
--- @param childfd lightuserdata socket handle
--- @param data string incoming stream data
--- @param len integer length of data
function aio:handle_as_http(elfd, childfd, data, len)
    local fd = aiosocket:new(elfd, childfd, true)
    self.fds[childfd] = fd

    self:buffered_cor(fd, function (resolve)
        while true do
            local header = coroutine.yield("\r\n\r\n")
            if not header then
                fd:close()
                break
            end
            local length = header:match("[Cc]ontent%-[Ll]ength: (%d+)")
            local body = ""
            if length and length ~= "0" then
                body = coroutine.yield(tonumber(length))
                if not body then
                    fd:close()
                    break
                end
            end
            local method, url, headers = aio:parse_http(header)
            local close = (headers["connection"] or "close"):lower() == "close"
            fd.cw = close
            aio:on_http(fd, method, url, headers, body)
            if close then
                break
            end
        end
    end)

    -- provide data event
    fd:on_data(elfd, childfd, data, len)
end

---Parse HTTP request
---
---@param data string http request
---@return string method HTTP method
---@return string url request URL
---@return {[string]: string} headers headers table
function aio:parse_http(data)
    local headers = {}
    local method, url, header = data:match("(.-) (.-) HTTP.-\r(.*)")

    for key, value in header:gmatch("\n(.-):[ ]*(.-)\r") do
        headers[key:lower()] = value
    end

    return method, url, headers
end

--- Parse HTTP query
--- @param query string query string
--- @return {[string]: string} query query params
function aio:parse_query(query)
    local params = {}
    query = "&" .. query
    -- match everything where first part doesn't contain = and second part doesn't contain &
    for key, value in query:gmatch("%&([^=]+)=?([^&]*)") do
        params[key] = self:parse_url(value)
    end
    return params
end


--- Parse URL encoded string
--- @param url string url encoded string
--- @return string text url decoded value
function aio:parse_url(url)
    local new = url:gsub("%+", " "):gsub("%%([0-9A-F][0-9A-F])", function(part)
        return string.char(tonumber(part, 16))
    end)
    return new
end

--- Add HTTP GET handler
--- @param url string URL
--- @param callback aiohttphandler handler
function aio:http_get(url, callback)
    self.http.GET[url] = callback
end

--- Add HTTP POST handler
--- @param url string URL
--- @param callback aiohttphandler handler
function aio:http_post(url, callback)
    self.http.POST[url] = callback
end

--- Add HTTP any handler
---@param method string HTTP method
---@param url string URL
---@param callback aiohttphandler handler
function aio:http_any(method, url, callback)
    self.http[method] = self.http[method] or {}
    self.http[method][url] = callback
end

--- Create a new TCP socket to host:port
--- @param elfd lightuserdata epoll handle
--- @param host string host name or IP address
--- @param port integer port
--- @return aiosocket|nil socket
--- @return string|nil error
function aio:connect(elfd, host, port)
    local sock, err = net.connect(elfd, host, port)
    if sock == nil then
        return nil, err
    end
    self.fds[sock] = aiosocket:new(elfd, sock, false)
    return self.fds[sock], nil
end

--- Handler called when socket is closed
--- @param elfd lightuserdata epoll handle
--- @param childfd lightuserdata socket handle
function aio:on_close(elfd, childfd)
    --- @type aiosocket
    local fd = self.fds[childfd]
    self.fds[childfd] = nil

    -- notify with close event, only once
    if fd ~= nil and not fd.closed then
        fd.closed = true
        fd.buf = {}
        fd:on_close(elfd, childfd)
    end
end

--- Handler called when socket is writeable
--- @param elfd lightuserdata epoll handle
--- @param childfd lightuserdata socket handle
function aio:on_write(elfd, childfd)
    local fd = self.fds[childfd]

    -- notify with connect event
    if fd ~= nil then
        fd:on_write(elfd, childfd)
    end
end

--- Initialize AIO hooks
function aio:start()
    --- Init handler
    --- @param elfd lightuserdata
    --- @param parentfd lightuserdata
    _G.on_init = function(elfd, parentfd)
        if aio.on_init then
            aio:on_init(elfd, parentfd)
        end
    end
    
    --- Data handler
    --- @param elfd lightuserdata
    --- @param childfd lightuserdata
    --- @param data string
    --- @param len integer
    _G.on_data = function(elfd, childfd, data, len)
        aio:on_data(elfd, childfd, data, len)
    end
    
    --- Close handler
    --- @param elfd lightuserdata
    --- @param childfd lightuserdata
    _G.on_close = function(elfd, childfd)
        aio:on_close(elfd, childfd)
    end
    
    --- Writeable handler
    --- @param elfd lightuserdata
    --- @param childfd lightuserdata
    _G.on_write = function(elfd, childfd)
        aio:on_write(elfd, childfd)
    end
end

--- Initialization handler
---
--- @param elfd lightuserdata epoll handle
--- @param parentfd lightuserdata server socket handle
function aio:on_init(elfd, parentfd)

end

--- Default HTTP request handler
--- @param fd aiosocket file descriptor
--- @param method string http method
--- @param url string URL
--- @param headers table headers table
--- @param body string request body
function aio:on_http(fd, method, url, headers, body)
    local pivot = url:find("?", 0, true)
    local script = url:sub(0, pivot and pivot - 1 or nil)
    local query = pivot and url:sub(pivot + 1) or ""
    local handlers = self.http[method]

    if handlers ~= nil then
        local handler = handlers[script]
        if handler ~= nil then
            handler(fd, query, headers, body)
            return
        end
    end

    fd:http_response("404 Not found", "text/plain", script .. " was not found on this server")
end

---Prepare promise
---@return function|thread on_resolved callback
---@return aiothen resolver
function aio:prepare_promise()
    local early, early_val = false, nil

    --- Resolve callback with coroutine return value
    --- This code is indeed repeated 3x in this repository to avoid unnecessary
    --- encapsulation on on_resolved (as it would be changed later and reference would be lost)
    --- and save us some performance
    --- @type aiocor|thread coroutine return values
    local on_resolved = function(...) early, early_val = true, {...} end

    --- Set AIO resolver callback
    --- @type aiothen
    local resolve_event = function(callback)
        if early then
            if type(callback) == "thread" then
                local ok, err = coroutine.resume(callback, unpack(early_val))
                if not ok then
                    error(err)
                end
            else
                callback(unpack(early_val))
            end
        else
            on_resolved = callback
        end
    end

    return function(...) 
        if type(on_resolved) == "thread" then
            local ok, err = coroutine.resume(on_resolved, ...)
            if not ok then
                error(err)
            end
        else
            return on_resolved(...)
        end
    end, resolve_event
end

--- Wrap event handlers into coroutine, example:
---
--- aio:cor(socket, "on_data", "on_close", function(stream)
---   local whole = ""
---   for item, length in stream() do
---      whole = whole .. item
---   end
---   print(whole)
--- end)
---
--- If called as aio:cor(target, callback), event_handler is assumed to be on_data
--- and close_handler is assumed to be on_close
---
--- @param target aiosocket object to be wrapped
--- @param event_handler string main event source that resumes coroutine
--- @param close_handler string|nil secondary event source that closes coroutine (sends nil data)
--- @param callback aiocor coroutine code, takes stream() that returns arguments (3, 4, ...) skipping elfd, childfd of event_handler
--- @return aiothen
function aio:cor2(target, event_handler, close_handler, callback)
    local data = nil
    local cor = self:cor0(callback)
    local on_resolved, resolve_event = self:prepare_promise()

    --- Resolver callable within coroutine
    --- @param ... any return value
    local resolver = function(...)
        on_resolved(...)
    end

    -- coroutine data iterator
    local provider = function()
        if data == nil then return end
        return unpack(data)
    end

    local running, ended = false, false

    -- main event handler that resumes coroutine as events arrive and provides data for iterator
    target[event_handler] = function(self, epfd, chdfd, ...)
        data = {...}

        -- if coroutine finished it's job, unsubscribe the event handler
        local status = coroutine.status(cor)
        if status == "dead" then
            target[event_handler] = function () end
            return
        end

        running = true
        local ok, result = coroutine.resume(cor, provider, resolver)
        running = false

        if not ok then
            print("aio.cor("..event_handler..") failed", result)
        end

        -- in case close event was invoked from the coroutine, it shall be handled here
        if ended then
            if coroutine.status(cor) ~= "dead" then
                ok, result = coroutine.resume(cor, provider, resolver)
                ended = false

                if not ok then
                    print("aio.cor(" .. event_handler .."|close) failed", result)
                end
            end
        end
    end

    -- closing event handler that sends nil signal to coroutine to terminate the iterator
    if close_handler ~= nil then
        target[close_handler] = function(self, ...)
            local status = coroutine.status(cor)
            if status == "dead" then
                target[close_handler] = function () end
                return
            end

            data = nil
            -- it might be possible that while coroutine is running, it issues a write together
            -- with close, in that case, this would be called while coroutine is still running
            -- and fail, therefore we issue ended=true signal, so after main handler finishes
            -- its job, it will close the coroutine for us instead
            
            if running then
                ended = true
            else
                local ok, result = coroutine.resume(cor, provider, resolver)
                if not ok then
                    print("aio.cor("..close_handler..") failed", result)
                end
            end
        end
    end

    return resolve_event
end

--- Wrap single event handler into a coroutine, evaluates to aio:cor2(target, event_handler, nil, callback)
---
--- @param target aiosocket object to be wrapped
--- @param event_handler string event source that resumes a coroutine
--- @param callback aiocor  coroutine code
--- @return aiothen
function aio:cor1(target, event_handler, callback)
    return self:cor2(target, event_handler, nil, callback)
end

--- Wrap aiosocket receiver into coroutine, evaluates to aio:cor2(target, "on_data", "on_close", callback)
---
--- @param target aiosocket object to be wrapped
--- @param callback aiocor coroutine code
--- @return aiothen
function aio:cor(target, callback)
    return self:cor2(target, "on_data", "on_close", callback)
end


--- Create a new coroutine
---@param callback fun(...: any): any
---@return thread coroutine
function aio:cor0(callback)
    return coroutine.create(callback)
end

--- Execute code in async environment so await can be used
---@param callback function to be ran
---@return thread coroutine
---@return boolean ok value
function aio:async(callback)
    local cor = aio:cor0(callback)
    local ok, result = coroutine.resume(cor)
    if not ok then
        print("aio.async failed: ", result)
    end
    return cor, ok
end

--- Await promise
---@param promise aiothen|thread promise object
---@return any ... response
function aio:await(promise)
    local self_cor = coroutine.running()

    if type(promise) == "thread" then
        local result = {coroutine.resume(promise)}
        if not result[1] then
            print("aio.await coroutine failed: ", result[2])
        end
        return unpack(result, 2)
    else
        promise(function(...)
            local ok, result = coroutine.resume(self_cor, ...)
            if not ok then
                print("aio.await failed: ", result)
            end
        end)
    end
    return coroutine.yield()
end


--- Buffered reader of aio:cor. Allows to read data stream
--- in buffered manner by calling coroutine.yield(n) to receive
--- n bytes of data from network or if n is a string, coroutine
--- is resumed after delimiter n in data was encountered, which
--- is useful for tasks like get all bytes until \0 or \r\n is
--- encountered.
---
--- Example:
--- aio:buffered_cor(fd, function(resolve)
---   local length = tonumber(coroutine.yield(4))
---   local data = coroutine.yield(length)
---   resolve(data)
--- end)
---@param target aiosocket file descriptor
---@param reader fun(resolve: fun(...: any)) reader coroutine
---@return aiothen 
function aio:buffered_cor(target, reader)
    return self:cor(target, function (stream, resolve)
        local reader = self:cor0(reader)
        -- resume the coroutine the first time and receive initial
        -- requested number of bytes to be read
        local ok, requested = coroutine.resume(reader, resolve)
        local read = ""
        local req_delim = false
        local exit = requested == nil
        local nil_resolve = false

        req_delim = type(requested) == "string"

        -- if we failed in very first step, return early and resolve with nil
        if not ok then
            print("aio.buffered_cor: coroutine failed in initial run", requested)
            resolve(nil)
            return
        end

        -- iterate over bytes from network as we receive them
        for data in stream do
            local prev = #read
            --- @type string
            read = read .. data

            -- check if state is ok, and if we read >= bytes requested to read
            while not exit and ok do
                local pivot = requested
                local skip = 1
                if req_delim then
                    local off = prev - #requested
                    if off < 0 then off = 0 end
                    pivot = read:find(requested, off, true)
                    skip = #requested
                end
                if not pivot or pivot > #read then
                    break
                end
                -- iterate over all surplus we have and resume the receiver coroutine
                -- with chunks of size requested by it
                ok, requested = coroutine.resume(reader, read:sub(1, pivot))
                req_delim = type(requested) == "string"

                if not ok then
                    -- if coroutine fails, exit and print error
                    print("aio.buffered_cor: coroutine failed to resume", requested)
                    nil_resolve = true
                    exit = true
                    break
                elseif requested == nil then
                    -- if coroutine is finished, exit
                    exit = true
                    break
                end
                if requested ~= nil then
                    read = read:sub(pivot + skip)
                end
            end
            -- if we ended reading in buffered reader, exit this loop
            if exit then
                break
            end
            coroutine.yield()
        end

        -- after main stream is over, signalize end by sending nil to the reader
        if coroutine.status(reader) ~= "dead" then
            ok, requested = coroutine.resume(reader, nil, "eof")
            if not ok then
                print("aio.buffered_cor: finishing coroutine failed", requested)
            end
        end

        -- if coroutine failed, resolve with nil value
        if nil_resolve then
            resolve(nil)
        end
    end)
end

--- Gather multiple asynchronous tasks
--- @param ... aiothen coroutine resolvers
--- @return aiothen resolver values
function aio:gather(...)
    local tasks = {...}
    local counter = #{...}
    local retvals = {}
    local on_resolved, resolve_event = self:prepare_promise()

    for i, task in ipairs(tasks) do
        table.insert(retvals, nil)
        local ok, err = pcall(task, function (value)
            counter = counter - 1
            retvals[i] = value
            if counter == 0 then
                on_resolved(unpack(retvals))
            end
        end)
        if not ok then
            print("aio.gather: task " .. i .. " failed to execute", err)
        end
    end

    if #tasks == 0 then
        on_resolved()
    end

    return resolve_event
end


--- Array map
---@param array table
---@param fn function
---@return table
function aio:map(array, fn)
    local new_array = {}
    for i=1,#array do
        new_array[i] = fn(array[i])
    end
    return new_array
end

--- Chain multiple AIO operations sequentially
--- @param first aiothen
--- @param ... fun(...: any): aiothen|any
--- @return aiothen retval return value of last task
function aio:chain(first, ...)
    local callbacks = {...}
    local at = 1
    local on_resolved, resolve_event = self:prepare_promise()

    local function next_callback(...)
        if at > #callbacks then
            on_resolved(...)
        else
            local callback = callbacks[at]
            local retval = callback(...)
            at = at + 1
            if type(retval) == "function" then
                retval(function (...)
                    local ok, err = pcall(next_callback, ...)
                    if not ok then
                        print("aio.chain: retval(next_callback) failed", err)
                    end
                end)
            else
                local ok, err = pcall(next_callback, retval)
                if not ok then
                    print("aio.chain: next_callback failed", err)
                end
            end
        end
    end

    first(function (...)
        local ok, err = pcall(next_callback, ...)
        if not ok then
            print("aio.chain: first call failed", err)
        end
    end)

    return resolve_event
end

aio:start()

return aio