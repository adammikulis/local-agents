extends RefCounted

## Engine arguments followed by the user arguments after `--`, de-duplicated.
static func all() -> PackedStringArray:
	var args: PackedStringArray = PackedStringArray()
	for arg in OS.get_cmdline_args():
		args.append(arg)
	for arg in OS.get_cmdline_user_args():
		if not args.has(arg):
			args.append(arg)
	return args

static func has_flag(flag: String) -> bool:
	for arg in all():
		if arg == flag:
			return true
	return false

## The integer after `prefix` on the first argument carrying it, else `fallback`.
static func int_value(prefix: String, fallback: int) -> int:
	for arg in all():
		if arg.begins_with(prefix):
			return int(arg.trim_prefix(prefix))
	return fallback
