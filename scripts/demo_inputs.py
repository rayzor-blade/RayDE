"""Build inputs for the published Pocket Studio preview."""
import hashlib


def inputs(root):
    return {path.relative_to(root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in root.rglob('*') if path.is_file()
            and path.relative_to(root).as_posix() not in ('data/tasks.json', 'README.md', '.gitignore')
            and path.relative_to(root).parts[0] not in ('bin', 'build', 'Export')
            and not any(part in ('.git', '.rayde', '.rayzor', '.haxelib', '.rayde-session') for part in path.relative_to(root).parts)}
