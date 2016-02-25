local private , public = {}, {}
Aux.scan = public

local PAGE_SIZE = 50

local state
local threads = {}

local scan_auctions, scan_auctions_helper, submit_query, wait_for_callback, wait_for_owner_data, abort, current_query, current_thread

function private.default_next_page(page, total_pages)
    local last_page = max(total_pages - 1, 0)
    if page < last_page then
        return page + 1
    end
end

function current_query()
    return current_thread().params.queries[current_thread().query_index]
end

function current_thread()
    for _, thread in pairs(threads) do
        if thread.id == Aux.control.thread_id then
            return thread
        end
    end
end

function public.start(params)
    public.abort(params.type)

    local thread_id = Aux.control.new_thread(private.scan)
    threads[params.type] = {
        id = thread_id,
        params = params,
    }
end

function public.abort(type)
    for t, thread in pairs(threads) do
        if not type or type == t then
            if thread.params.on_abort then
                thread.params.on_abort()
            end
            threads[t] = nil
            Aux.control.kill_thread(thread.id)
        end
    end
end

function private.wait_for_results(k)
    if current_thread().params.type == 'bidder' then
        return private.wait_for_bidder_results(k)
    elseif current_thread().params.type == 'owner' then
        return private.wait_for_owner_results(k)
    elseif current_thread().params.type == 'list' then
        return private.wait_for_list_results(k)
    end
end

function private.wait_for_bidder_results(k)
    if Aux.bids_loaded then
        return k()
    else -- recurse on the next update
        return Aux.control.wait(private.wait_for_bidder_results, k)
    end
end

function private.wait_for_owner_results(k)
    local updated
    if current_thread().page == Aux.current_owner_page then
        updated = true
    else
        Aux.control.on_next_event('AUCTION_OWNED_LIST_UPDATE', function()
            updated = true
        end)
    end

    Aux.control.wait_until(function() return updated end, k)
end

function private.wait_for_list_results(k)
    local updated, last_update
    local listener = Aux.control.event_listener('AUCTION_ITEM_LIST_UPDATE', function()
        last_update = GetTime()
        updated = true
    end)
    listener:start()
    Aux.control.wait_until(function()
        -- order important, owner_data_complete must be called after an update to request missing data
        local ok = updated and private.owner_data_complete() or last_update and GetTime() - last_update > 5
        updated = false
        return ok
    end, function()
        listener:stop()
        return k()
    end)
end

function private.owner_data_complete()
    if current_thread().params.no_wait_owner then
        return true
    end
    local count, _ = GetNumAuctionItems(current_thread().params.type)
    for i=1,count do
        local auction_info = Aux.info.auction(i, current_thread().params.type)
        if auction_info and not auction_info.owner then
            return false
        end
    end
    return true
end

function wait_for_callback(args) -- the arguments must not be nil!
	local ok = true

    local f = tremove(args, 1)
    local k = tremove(args)

	if f then
		tinsert(args, {
			suspend = function() ok = false end,
			resume = function() ok = true end,
		})
		f(unpack(args))
	end

	if ok then
		return k()
    else
        return Aux.control.wait_until(function() return ok end, k)
	end
end


function private.scan()
    local start_query_index = current_thread().params.start_query_index or 1
    local next_query_index = current_thread().params.next_query_index or function(query_index) return query_index + 1 end

    current_thread().query_index = current_thread().query_index and next_query_index(current_thread().query_index) or start_query_index
    if current_query() then
        wait_for_callback{current_thread().params.on_start_query or Aux.util.pass, current_thread().query_index, function()
            current_thread().page = current_query().start_page
            return private.process_query()
        end }
    else
        local on_complete = current_thread().params.on_complete
        threads[Aux.control.thread_id] = nil
        if on_complete then
            return on_complete()
        end
    end
end

function private.process_query()

    submit_query(function()

        local count, _ = GetNumAuctionItems(current_thread().params.type)

        scan_auctions(count, function()

            wait_for_callback{current_thread().params.on_page_scanned or Aux.util.pass, function()
                if current_query().next_page then
                    current_thread().page = current_query().next_page(current_thread().page, current_thread().total_pages)
                else
                    current_thread().page = private.default_next_page(current_thread().page, current_thread().total_pages)
                end

                if current_thread().page then
                    return private.process_query()
                else
                    return private.scan()
                end
            end}
        end)
    end)
end

function scan_auctions(count, k)
	return scan_auctions_helper(1, count, k)
end

function scan_auctions_helper(i, n, k)
    local recurse = function()
        if i >= n then
            return k()
        else
            return scan_auctions_helper(i + 1, n, k)
        end
    end

    local auction_info = Aux.info.auction(i, current_thread().params.type)
    if auction_info then
        auction_info.index = i
        auction_info.page = current_thread().page
        auction_info.query = current_query()
        auction_info.query_type = current_thread().params.type

        Aux.history.process_auction(auction_info)

        if not current_query().validator or current_query().validator(auction_info) then
            return wait_for_callback{current_thread().params.on_read_auction or Aux.util.pass, auction_info, recurse }
        end
    end

    return recurse()
end

function submit_query(k)
	if current_thread().page then
        Aux.control.wait_until(function() return current_thread().params.type ~= 'list' or CanSendAuctionQuery() end, function()

            if current_thread().params.on_submit_query then
                current_thread().params.on_submit_query()
            end
            if current_thread().params.type == 'bidder' then
                GetBidderAuctionItems(current_thread().page)
            elseif current_thread().params.type == 'owner' then
                GetOwnerAuctionItems(current_thread().page)
            else
                QueryAuctionItems(
                    Aux.util.safe_index{current_query(), 'blizzard_query', 'name'},
                    Aux.util.safe_index{current_query(), 'blizzard_query', 'min_level'},
                    Aux.util.safe_index{current_query(), 'blizzard_query', 'max_level'},
                    Aux.util.safe_index{current_query(), 'blizzard_query', 'slot'},
                    Aux.util.safe_index{current_query(), 'blizzard_query', 'class'},
                    Aux.util.safe_index{current_query(), 'blizzard_query', 'subclass'},
                    current_thread().page,
                    Aux.util.safe_index{current_query(), 'blizzard_query', 'usable'},
                    Aux.util.safe_index{current_query(), 'blizzard_query', 'quality'}
                )
            end
            private.wait_for_results(function()
                local _, total_count = GetNumAuctionItems(current_thread().params.type)
                current_thread().total_pages = math.ceil(total_count / PAGE_SIZE)
                if current_thread().total_pages >= current_thread().page + 1 then
                    wait_for_callback{current_thread().params.on_page_loaded or Aux.util.pass, current_thread().page, current_thread().total_pages, function()
                        return k()
                    end}
                else
                    return k()
                end
            end)
		end)
	else
		return k()
	end
end
