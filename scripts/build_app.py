#!/usr/bin/env python3
# Builds nxnative Converter, the Mac app that runs the whole Switch → Mac route from a window (docs/development.md, "nxnative Converter"), and installs it:
#   swift build -c release of the Swift package dm/mac/converter (its output on the console) → the icon (dm/mac/converter/Icon/make_icon.swift renders a 1024 px PNG, sips and
#   iconutil make AppIcon.icns; without them the app has no icon, with a warning) → <out>.partial/Contents/{MacOS/NXNativeConverter, Info.plist, PkgInfo, Resources/AppIcon.icns}
#   → codesign (ad-hoc unless --sign) → swapped into place in one step (renamex_np RENAME_SWAP), the old app then to the Trash, so a failed build leaves the installed
#   app as it was.
#   An app at <out> is replaced only when it is nxnative Converter (bundle ID org.nxnative.converter): -o naming another app by mistake stops before the build.
# Info.plist records the repository (NXConverterRepository) and its HEAD (NXConverterCommit) the app was built from: the app finds nxnative there, and offers to rebuild itself
#   when a pull changes dm/mac/converter or this script. CFBundleVersion is the repository's commit count.
# Usage: python3 scripts/build_converter_app.py [-o OUT.app] [--sign IDENTITY] [--open] [--scratch-path DIR]   (default: /Applications/nxnative Converter.app)
#   Needs a Mac with Xcode (or a Swift toolchain with the macOS SDK). Exit code 0 when done, 1 on an error, 130 when interrupted. The app updates itself by running this script.
import argparse, ctypes, errno, os, plistlib, shutil, subprocess, sys, tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PACKAGE = REPO / 'dm/mac/converter'
APP_NAME = 'nxnative Converter'
EXE = 'NXNativeConverter'   # the package's executable product
BUNDLE_ID = 'org.nxnative.converter'
DEFAULT_OUT = Path('/Applications') / f'{APP_NAME}.app'
ICON_SIZES = (16, 32, 128, 256, 512)
GAME_EXTENSIONS = ['nsp', 'xci', 'nsz', 'xcz']
TOOL_PATHS = ['/opt/homebrew/bin', '/usr/local/bin', '/usr/local/share/dotnet', os.path.expanduser('~/.dotnet')]   # as the NSP script's: a GUI app does not get the shell's PATH
ACCESS = f'{APP_NAME} reads the game files in the folders you add and writes the game\'s app beside them.'   # the privacy prompts for folders and drives
RENAME_SWAP = 0x2   # <stdio.h>
# NSFileManager's trashItemAtURL through JavaScript for Automation, which scripts no app and so asks for no permission (macOS 14 has no /usr/bin/trash)
TRASH_JS = ('function run(argv) { ObjC.import("Foundation"); '
            'return $.NSFileManager.defaultManager.trashItemAtURLResultingItemURLError($.NSURL.fileURLWithPath(argv[0]), null, null) }')


class BuildError(Exception):
    pass


def tool_env():   # the caller's PATH first (its swift), then the usual tool folders and the system's
    path = [p for p in os.environ.get('PATH', '').split(os.pathsep) if p]
    path += [p for p in TOOL_PATHS + ['/usr/bin', '/bin', '/usr/sbin', '/sbin'] if p not in path]
    return dict(os.environ, PATH=os.pathsep.join(path))


def run(cmd, env=None, capture=True):
    cmd = [str(c) for c in cmd]
    try: r = subprocess.run(cmd, env=env, capture_output=capture, text=True)
    except OSError as e: raise BuildError(f'{Path(cmd[0]).name}: {e.strerror or e}') from e
    if r.returncode:
        err = ((r.stderr or r.stdout or '').strip().splitlines() or [''])[-1] if capture else ''
        raise BuildError(f'{Path(cmd[0]).name} {cmd[1] if len(cmd) > 1 else ""} failed (exit code {r.returncode})' + (f': {err}' if err else ''))
    return r.stdout or ''


def git(*args):   # None outside a git work tree (or without git)
    try: r = subprocess.run(['git', '-C', str(REPO), *args], capture_output=True, text=True)
    except OSError: return None
    return r.stdout.strip() if r.returncode == 0 and r.stdout.strip() else None


def info_plist(repo, commit, count, icon):
    """The app's Info.plist: folders and the game files open in it (from Finder, the Dock icon, Open With), NXConverterRepository / NXConverterCommit for ConverterInfo"""
    p = {'CFBundleName': APP_NAME, 'CFBundleDisplayName': APP_NAME, 'CFBundleIdentifier': BUNDLE_ID, 'CFBundleExecutable': EXE, 'CFBundlePackageType': 'APPL',
         'CFBundleShortVersionString': '1.0', 'CFBundleVersion': str(count or 1), 'CFBundleInfoDictionaryVersion': '6.0', 'CFBundleDevelopmentRegion': 'en',
         'LSMinimumSystemVersion': '27.0', 'NSHighResolutionCapable': True, 'LSApplicationCategoryType': 'public.app-category.utilities', 'NSPrincipalClass': 'NSApplication',
         'CFBundleDocumentTypes': [{'CFBundleTypeName': 'Folder', 'CFBundleTypeRole': 'Viewer', 'LSItemContentTypes': ['public.folder'], 'LSHandlerRank': 'Alternate'},
                                   {'CFBundleTypeName': 'Switch game file', 'CFBundleTypeRole': 'Viewer', 'LSItemContentTypes': ['org.nxnative.switch-game'], 'LSHandlerRank': 'Alternate'}],
         'UTImportedTypeDeclarations': [{'UTTypeIdentifier': 'org.nxnative.switch-game', 'UTTypeDescription': 'Switch game file', 'UTTypeConformsTo': ['public.data'],
                                         'UTTypeTagSpecification': {'public.filename-extension': GAME_EXTENSIONS}}],
         'NXConverterRepository': str(repo)}
    for key in ('NSDesktopFolderUsageDescription', 'NSDocumentsFolderUsageDescription', 'NSDownloadsFolderUsageDescription', 'NSRemovableVolumesUsageDescription',
                'NSNetworkVolumesUsageDescription'):
        p[key] = ACCESS
    if commit: p['NXConverterCommit'] = commit
    if icon: p['CFBundleIconFile'] = 'AppIcon'
    return p


def sign(app, identity, env=None):
    try: run(['codesign', '--force', '--sign', identity, app], env)
    except BuildError as e:
        if 'detritus' not in str(e): raise
        run(['xattr', '-cr', app], env); run(['codesign', '--force', '--sign', identity, app], env)   # Finder information or resource forks on copied files: codesign refuses them


def bundle_id(app):   # CFBundleIdentifier of the bundle at app, None when it has none or no readable Info.plist
    try: p = plistlib.loads((Path(app) / 'Contents/Info.plist').read_bytes())
    except (OSError, ValueError): return None
    return p.get('CFBundleIdentifier') if isinstance(p, dict) else None


def check_replaceable(out):   # nothing at out, or a build of this app: never another app that -o names by mistake
    if not (out.exists() or out.is_symlink()): return
    found = bundle_id(out)
    if found != BUNDLE_ID:
        raise BuildError(f'{out} is not {APP_NAME} ({f"its bundle ID is {found}" if found else "it has no bundle ID"}) and is left as it is: give another place with -o')


def trash(path, env=None):   # True when path went to the Trash
    try: r = subprocess.run(['osascript', '-l', 'JavaScript', '-e', TRASH_JS, str(path)], env=env, capture_output=True, text=True)
    except OSError: return False
    return r.returncode == 0 and r.stdout.strip() == 'true'


def swap_in(new, out):   # new renamed to out in one step; where the app that was at out now is, None when there was none
    if not (out.exists() or out.is_symlink()): new.rename(out); return None
    if ctypes.CDLL(None, use_errno=True).renamex_np(os.fsencode(new), os.fsencode(out), RENAME_SWAP) == 0: return new
    e = ctypes.get_errno()
    if e not in (errno.ENOTSUP, errno.EINVAL): raise OSError(e, os.strerror(e), str(out))
    aside = new.parent / 'old' / out.name   # a volume without the swap (exFAT, SMB): the old app aside, put back when the rename fails
    aside.parent.mkdir(); out.rename(aside)
    try: new.rename(out)
    except OSError: aside.rename(out); raise
    return aside


def assemble(binary, out, icon, plist, identity=None, env=None):
    """<out>'s folder/.<out>.<random>/<out name>/Contents/{MacOS/NXNativeConverter, Info.plist, PkgInfo, Resources/AppIcon.icns}, signed when identity is given, then swapped into
    place; the app it replaces (only nxnative Converter, check_replaceable) goes to the Trash, or is removed when the Trash cannot take it"""
    out = Path(out)
    stage = Path(tempfile.mkdtemp(prefix=f'.{out.name}.', dir=out.parent))
    try:
        tmp = stage / out.name; c = tmp / 'Contents'
        (c / 'MacOS').mkdir(parents=True); (c / 'Resources').mkdir()
        shutil.copy2(binary, c / 'MacOS' / EXE)
        if icon: shutil.copy2(icon, c / 'Resources/AppIcon.icns')
        (c / 'Info.plist').write_bytes(plistlib.dumps(plist))
        (c / 'PkgInfo').write_text('APPL????')
        if identity: sign(tmp, identity, env)
        check_replaceable(out)   # build() checks it before the Swift build too, which takes minutes
        old = swap_in(tmp, out)
        if old and not trash(old, env): print(f'the old app could not go to the Trash: removing it ({out})', flush=True)
    finally: shutil.rmtree(stage, ignore_errors=True)
    return out


def make_icns(work, env):   # AppIcon.icns in work, or None with a warning: the app works without an icon
    png, iconset = work / 'icon.png', work / 'AppIcon.iconset'
    try:
        run(['swift', PACKAGE / 'Icon/make_icon.swift', png], env)
        iconset.mkdir()
        for n in ICON_SIZES:
            for k, suffix in ((1, ''), (2, '@2x')):
                run(['sips', '-z', n * k, n * k, png, '--out', iconset / f'icon_{n}x{n}{suffix}.png'], env)
        run(['iconutil', '-c', 'icns', iconset, '-o', work / 'AppIcon.icns'], env)
        return work / 'AppIcon.icns'
    except (BuildError, OSError) as e:
        print(f'[RED] no app icon: {e}', flush=True)
        return None


def writable_folder(out):
    d = out.parent
    try: d.mkdir(parents=True, exist_ok=True)
    except OSError: pass
    if not (d.is_dir() and os.access(d, os.W_OK)):
        hint = '~/Applications/nxnative\\ Converter.app' if d == DEFAULT_OUT.parent else 'a folder you can write to'
        raise BuildError(f'cannot write to {d}: give another place with -o, e.g. -o {hint}')


def build(a):
    if sys.platform != 'darwin': raise BuildError('nxnative Converter is a Mac app: build it on a Mac')
    out = Path(os.path.expanduser(a.out)).resolve() if a.out else DEFAULT_OUT
    if out.suffix != '.app': raise BuildError(f'the output must end in .app: {out}')
    writable_folder(out)
    check_replaceable(out)
    env = tool_env()
    if not shutil.which('swift', path=env['PATH']): raise BuildError('swift not found: install Xcode (App Store) and open it once')
    swift = ['swift', 'build', '-c', 'release', '--package-path', PACKAGE] + (['--scratch-path', Path(os.path.expanduser(a.scratch_path)).resolve()] if a.scratch_path else [])
    print(f'building {APP_NAME} (swift build -c release, {PACKAGE.relative_to(REPO)})', flush=True)
    run(swift, env, capture=False)
    binary = Path(run(swift + ['--show-bin-path'], env).strip().splitlines()[-1]) / EXE
    if not binary.is_file(): raise BuildError(f'no {EXE} after the build: {binary}')
    commit = git('rev-parse', 'HEAD')
    count = git('rev-list', '--count', 'HEAD') if commit else None
    with tempfile.TemporaryDirectory() as work:
        print('rendering the icon', flush=True)
        icon = make_icns(Path(work), env)
        print(f'signing ({"ad-hoc" if a.sign == "-" else a.sign}) and installing', flush=True)
        assemble(binary, out, icon, info_plist(REPO, commit, count, icon), a.sign, env)
    print(f'done: {out}', flush=True)
    if a.open: run(['open', out], env)


def parse(argv):
    ap = argparse.ArgumentParser(prog='build_converter_app.py', description=f'Build {APP_NAME}, the Mac app that converts a folder of Switch game files into a Mac app, and install it.',
                                 epilog='example: python3 scripts/build_converter_app.py -o ~/Applications/nxnative\\ Converter.app --open')
    ap.add_argument('-o', '--out', metavar='OUT.app', help=f'the app (default: {DEFAULT_OUT}); nxnative Converter already there is replaced '
                    '(the old one to the Trash), any other app stops the build')
    ap.add_argument('--sign', default='-', metavar='IDENTITY', help='codesign identity, e.g. "Developer ID Application: <name> (<team>)" (default: - = ad-hoc)')
    ap.add_argument('--open', action='store_true', help='open the app when it is built')
    ap.add_argument('--scratch-path', metavar='DIR', help='swift build\'s build folder (default: the package\'s own .build)')
    return ap.parse_args(argv)


def main(argv):   # the exit code: 0 done, 1 error, 130 interrupted
    a = parse(argv)
    try: build(a)
    except (BuildError, OSError) as e:   # OSError: a file the swap could not move or remove
        print(f'[RED] {e}', file=sys.stderr, flush=True); return 1
    except KeyboardInterrupt:
        print('[RED] interrupted', file=sys.stderr, flush=True); return 130
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
