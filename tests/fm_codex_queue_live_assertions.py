def assert_busy_order(items, busy_input, queued_receipt):
    input_turns = [item.get('payload', {}).get('internal_chat_message_metadata_passthrough', {}).get('turn_id')
                   for item in items if item.get('type') == 'response_item'
                   and item.get('payload', {}).get('type') == 'message'
                   and item.get('payload', {}).get('role') == 'user'
                   and any(part.get('text') == busy_input for part in item.get('payload', {}).get('content', []))]
    if len(input_turns) != 1 or not input_turns[0]:
        raise ValueError('busy input must identify one exact native turn')
    busy_turn = input_turns[0]
    queued_turn = queued_receipt['handled']['turn']
    if not queued_turn or busy_turn == queued_turn:
        raise ValueError('busy and queued handling turns must differ')
    queued_inputs = [item for item in items if item.get('type') == 'response_item'
                     and item.get('payload', {}).get('type') == 'message'
                     and item.get('payload', {}).get('role') == 'user'
                     and item.get('payload', {}).get('internal_chat_message_metadata_passthrough', {}).get('turn_id') == queued_turn
                     and any(part.get('text') == queued_receipt['message'] for part in item.get('payload', {}).get('content', []))]
    if len(queued_inputs) != 1:
        raise ValueError('queued receipt must match the exact native input')
    positions = {}
    for name, turn, event in [('busy_start', busy_turn, 'task_started'), ('busy_complete', busy_turn, 'task_complete'), ('queued_start', queued_turn, 'task_started')]:
        matches = [index for index, item in enumerate(items) if item.get('type') == 'event_msg'
                   and item.get('payload', {}).get('turn_id') == turn
                   and item.get('payload', {}).get('type') == event]
        if len(matches) != 1:
            raise ValueError('missing or ambiguous native turn event: ' + name)
        positions[name] = matches[0]
    if not positions['busy_start'] < positions['busy_complete'] < positions['queued_start']:
        raise ValueError('queued handling started before the busy turn completed')
    return dict(positions, busy_turn=busy_turn, queued_turn=queued_turn)


def assert_restart_recovery(items, pending, later_event, receipts):
    original = [receipt for receipt in receipts if any(line in receipt['buffer'].splitlines() for line in pending['buffer'].splitlines())]
    later = [receipt for receipt in receipts if later_event in receipt['buffer'].splitlines()]
    if len(original) != 1 or original[0]['id'] != pending['id'] or original[0]['message'] != pending['message'] or original[0]['buffer'] != pending['buffer']:
        raise ValueError('original submission must retain one exact acknowledgement across restart')
    if len(later) != 1 or later[0]['id'] == pending['id']:
        raise ValueError('later buffered event must receive its own acknowledgement')
    for receipt in [original[0], later[0]]:
        inputs = [item['payload'] for item in items if item.get('type') == 'response_item'
                  and item.get('payload', {}).get('type') == 'message'
                  and item.get('payload', {}).get('role') == 'user'
                  and any(part.get('text') == receipt['message'] for part in item.get('payload', {}).get('content', []))]
        turn = receipt['handled']['turn']
        if not turn or len(inputs) != 1 or inputs[0].get('internal_chat_message_metadata_passthrough', {}).get('turn_id') != turn:
            raise ValueError('restart receipt must match one exact native input')
        starts = [index for index, item in enumerate(items) if item.get('type') == 'event_msg'
                  and item.get('payload', {}).get('type') == 'task_started' and item['payload'].get('turn_id') == turn]
        completes = [index for index, item in enumerate(items) if item.get('type') == 'event_msg'
                     and item.get('payload', {}).get('type') == 'task_complete' and item['payload'].get('turn_id') == turn]
        if len(starts) != 1 or len(completes) != 1 or starts[0] >= completes[0]:
            raise ValueError('restart acknowledgement requires one started and completed native turn')
    return dict(pending_id=pending['id'], original_turn=original[0]['handled']['turn'], later_id=later[0]['id'], later_turn=later[0]['handled']['turn'])
