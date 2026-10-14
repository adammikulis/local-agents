extends RefCounted

static func disconnect_reply(agent: LocalAgent, completion: Callable, progress: Callable) -> void:
    if not is_instance_valid(agent):
        return
    if completion.is_valid() and agent.think_completed.is_connected(completion):
        agent.think_completed.disconnect(completion)
    if progress.is_valid() and agent.reply_updated.is_connected(progress):
        agent.reply_updated.disconnect(progress)
