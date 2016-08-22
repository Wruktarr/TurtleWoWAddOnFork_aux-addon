module 'stack'

state = nil

function stack_size(slot)
    local container_item_info = info.container_item(unpack(slot))
    return container_item_info and container_item_info.count or 0
end

function charges(slot)
    local container_item_info = info.container_item(unpack(slot))
	return container_item_info and container_item_info.charges
end

function max_stack(slot)
	local container_item_info = info.container_item(unpack(slot))
	return container_item_info and container_item_info.max_stack
end

function locked(slot)
	local container_item_info = info.container_item(unpack(slot))
	return container_item_info and container_item_info.locked
end

function find_item_slot(partial)
	for slot in inventory do
		if matching_item(slot, partial) and not eq(slot, state.target_slot) then
			return slot
		end
	end
end

function matching_item(slot, partial)
	local item_info = info.container_item(unpack(slot))
	return item_info and item_info.item_key == state.item_key and info.auctionable(item_info.tooltip) and (not partial or item_info.count < item_info.max_stack)
end

function find_empty_slot()
	for slot, type in inventory do
		if type == 1 and not GetContainerItemInfo(unpack(slot)) then
			return slot
		end
	end
end

function find_charge_item_slot()
	for slot in inventory do
		if matching_item(slot) and charges(slot) == state.target_size then
			return slot
		end
	end
end

function move_item(from_slot, to_slot, amount, k)
	if locked(from_slot) or locked(to_slot) then
		return wait(k)
	end

	amount = min(max_stack(from_slot) - stack_size(to_slot), stack_size(from_slot), amount)
	local expected_size = stack_size(to_slot) + amount

	ClearCursor()
	SplitContainerItem(from_slot[1], from_slot[2], amount)
	PickupContainerItem(unpack(to_slot))

	return when(function() return stack_size(to_slot) == expected_size end, k)
end

function process()

	if not state.target_slot or not matching_item(state.target_slot) then
		state.target_slot = find_item_slot()
		if not state.target_slot then
			return stop()
		end
	end

	if charges(state.target_slot) then
		state.target_slot = find_charge_item_slot()
		return stop()
	end
	if stack_size(state.target_slot) > state.target_size then
		local slot = find_item_slot(true) or find_empty_slot()
		if slot then
			return move_item(
				state.target_slot,
				slot,
				stack_size(state.target_slot) - state.target_size,
				process
			)
		end
	elseif stack_size(state.target_slot) < state.target_size then
		local slot = find_item_slot()
		if slot then
			return move_item(
				slot,
				state.target_slot,
				state.target_size - stack_size(state.target_slot),
				process
			)
		end
	end
	return stop()
end

function public.stop()
	if state then
		kill_thread(state.thread_id)
		local callback, slot = state.callback, state.target_slot
		if slot and not matching_item(slot) then
			slot = nil
		end
		state = nil
		call(callback, slot)
	end
end

function public.start(item_key, size, callback)
	stop()

	local thread_id = thread(process)
	state = {
		thread_id = thread_id,
		item_key = item_key,
		target_size = size,
		callback = callback,
	}
end