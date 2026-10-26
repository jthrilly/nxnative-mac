"""scripts/build_converter_app.py without building Swift: nxnative Converter's Info.plist (the folders and game files it opens, the imported game file type, the repository and
commit it was built from), the bundle assemble() writes around a stand-in binary (layout, PkgInfo, the staging folder swapped into place with nothing left beside it, a converter
already there replaced and sent to the Trash, any other app at -o left as it is, the swap on a volume without RENAME_SWAP, the old app kept when assembling fails, an ad-hoc
signature), and the checks made before the build (the output folder, an app that is not the converter, the exit codes)."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('build_converter_app', REPO / 'scripts/build_converter_app.py')
bca = importlib.util.module_from_spec(spec); spec.loader.exec_module(bca)
SHA = '0123456789abcdef0123456789abcdef01234567'
APP = 'nxnative Converter.app'


class Plist(unittest.TestCase):
    def test_keys(self):
        p = bca.info_plist(REPO, SHA, 1234, True)
        self.assertEqual((p['CFBundleName'], p['CFBundleDisplayName'], p['CFBundleIdentifier'], p['CFBundleExecutable'], p['CFBundlePackageType']),
                         ('nxnative Converter', 'nxnative Converter', 'org.nxnative.converter', 'NXNativeConverter', 'APPL'))
        self.assertEqual((p['CFBundleShortVersionString'], p['CFBundleVersion'], p['LSMinimumSystemVersion'], p['CFBundleIconFile']), ('1.0', '1234', '27.0', 'AppIcon'))
        self.assertEqual((p['NSPrincipalClass'], p['NSHighResolutionCapable'], p['LSApplicationCategoryType']), ('NSApplication', True, 'public.app-category.utilities'))
        self.assertEqual((p['NXConverterRepository'], p['NXConverterCommit']), (str(REPO), SHA))
        self.assertEqual(plistlib.loads(plistlib.dumps(p)), p)

    def test_document_types(self):   # folders and the game files: dropped on the Dock icon, Open With; never the default app for either
        p = bca.info_plist(REPO, SHA, 1, False)
        docs = {t: d for d in p['CFBundleDocumentTypes'] for t in d['LSItemContentTypes']}
        self.assertEqual(sorted(docs), ['org.nxnative.switch-game', 'public.folder'])
        self.assertEqual({(d['CFBundleTypeRole'], d['LSHandlerRank']) for d in docs.values()}, {('Viewer', 'Alternate')})
        ut, = p['UTImportedTypeDeclarations']
        self.assertEqual((ut['UTTypeIdentifier'], ut['UTTypeConformsTo']), ('org.nxnative.switch-game', ['public.data']))
        self.assertEqual(sorted(ut['UTTypeTagSpecification']['public.filename-extension']), ['nsp', 'nsz', 'xci', 'xcz'])

    def test_without_git_or_icon(self):
        p = bca.info_plist(Path('/x/nxnative'), None, None, None)
        self.assertNotIn('NXConverterCommit', p); self.assertNotIn('CFBundleIconFile', p)
        self.assertEqual((p['CFBundleVersion'], p['NXConverterRepository']), ('1', '/x/nxnative'))

    def test_tool_path(self):   # the caller's PATH first (its swift), then the tool folders a GUI app lacks
        with mock.patch.dict(os.environ, PATH='/my/bin:/usr/bin'):
            path = bca.tool_env()['PATH'].split(os.pathsep)
        self.assertEqual(path[:2], ['/my/bin', '/usr/bin'])
        self.assertEqual(path.count('/usr/bin'), 1)
        for p in bca.TOOL_PATHS + ['/bin', '/usr/sbin', '/sbin']: self.assertIn(p, path)


class Trash(unittest.TestCase):   # osascript's JavaScript for Automation, stood in for: the tests never fill the user's Trash
    def test_trash(self):
        for rc, out, osfail, want in ((0, 'true\n', False, True), (0, 'false\n', False, False), (1, '', False, False), (0, '', True, False)):
            with self.subTest(rc=rc, out=out, osfail=osfail):
                done = subprocess.CompletedProcess([], rc, out, '')
                with mock.patch.object(bca.subprocess, 'run', side_effect=OSError('no osascript') if osfail else None, return_value=done) as run:
                    self.assertIs(bca.trash(Path('/x/old.app')), want)
                cmd = run.call_args.args[0]
                self.assertEqual((cmd[:4], cmd[-1]), (['osascript', '-l', 'JavaScript', '-e'], '/x/old.app')); self.assertIn('trashItemAtURL', cmd[4])


class Assemble(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()).resolve(); self.addCleanup(shutil.rmtree, self.tmp)
        self.binary = self.tmp / 'stub'
        self.binary.write_text('#!/bin/sh\necho converter "$@"\n'); self.binary.chmod(0o755)
        self.icon = self.tmp / 'AppIcon.icns'; self.icon.write_bytes(b'icns\0\0\0\x08')
        self.apps = self.tmp / 'Applications'; self.apps.mkdir()
        self.out = self.apps / APP
        self.bin = self.tmp / 'Trash'; self.bin.mkdir(); self.trash_ok = True
        mock.patch.object(bca, 'trash', side_effect=self.trash).start(); self.addCleanup(mock.patch.stopall)   # never the user's own Trash

    def trash(self, path, env=None):
        if self.trash_ok: Path(path).rename(self.bin / f'{len(list(self.bin.iterdir()))} {Path(path).name}')
        return self.trash_ok

    def version(self, app=None):
        return plistlib.loads(((app or self.out) / 'Contents/Info.plist').read_bytes())['CFBundleVersion']

    def foreign(self, ident='com.apple.dt.Xcode'):   # another app at -o
        (self.out / 'Contents').mkdir(parents=True)
        if ident: (self.out / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': ident}))
        (self.out / 'Contents/keep').write_text('mine')

    def assemble(self, icon=True, count=7, **kw):
        return bca.assemble(self.binary, self.out, self.icon if icon else None, bca.info_plist(REPO, SHA, count, icon), **kw)

    def test_layout(self):
        self.assertEqual(self.assemble(), self.out)
        c = self.out / 'Contents'
        self.assertEqual(sorted(str(p.relative_to(self.out)) for p in self.out.rglob('*')),
                         ['Contents', 'Contents/Info.plist', 'Contents/MacOS', 'Contents/MacOS/NXNativeConverter', 'Contents/PkgInfo', 'Contents/Resources', 'Contents/Resources/AppIcon.icns'])
        self.assertEqual((c / 'PkgInfo').read_text(), 'APPL????')
        self.assertTrue(os.access(c / 'MacOS/NXNativeConverter', os.X_OK))
        self.assertEqual((c / 'Resources/AppIcon.icns').read_bytes(), self.icon.read_bytes())
        p = plistlib.loads((c / 'Info.plist').read_bytes())
        self.assertEqual((p['CFBundleExecutable'], p['CFBundleVersion'], p['CFBundleIconFile'], p['NXConverterCommit']), ('NXNativeConverter', '7', 'AppIcon', SHA))
        self.assertEqual([p.name for p in self.apps.iterdir()], [APP])   # no staging folder beside it
        self.assertEqual(list(self.bin.iterdir()), [])

    def test_no_icon(self):
        self.assemble(icon=False)
        self.assertEqual(list((self.out / 'Contents/Resources').iterdir()), [])
        self.assertNotIn('CFBundleIconFile', plistlib.loads((self.out / 'Contents/Info.plist').read_bytes()))

    def test_replaces(self):   # the converter already there goes to the Trash; the new one is whole; files beside it that the script did not make stay
        self.assemble(count=1)
        (self.out / 'Contents/stale').write_text('x')
        for other in (APP + '.partial', APP + '.old'): (self.apps / other / 'Contents').mkdir(parents=True)
        self.assemble(icon=False, count=2)
        self.assertFalse((self.out / 'Contents/stale').exists()); self.assertFalse((self.out / 'Contents/Resources/AppIcon.icns').exists())
        self.assertEqual(self.version(), '2')
        self.assertEqual(sorted(p.name for p in self.apps.iterdir()), [APP, APP + '.old', APP + '.partial'])
        trashed, = self.bin.iterdir()
        self.assertEqual((trashed.name, self.version(trashed)), (f'0 {APP}', '1')); self.assertTrue((trashed / 'Contents/stale').exists())

    def test_replaces_without_trash(self):   # the Trash refuses it (a volume without one): the old converter is removed all the same
        self.assemble(count=1); self.trash_ok = False
        with contextlib.redirect_stdout(io.StringIO()) as out: self.assemble(count=2)
        self.assertIn('could not go to the Trash', out.getvalue())
        self.assertEqual((self.version(), [p.name for p in self.apps.iterdir()]), ('2', [APP]))

    def test_refuses_another_app(self):   # -o naming another app by mistake (or a bundle without an Info.plist): left as it is, nothing written beside it
        for ident, why in (('com.apple.dt.Xcode', 'its bundle ID is com.apple.dt.Xcode'), (None, 'it has no bundle ID')):
            with self.subTest(ident=ident):
                self.foreign(ident)
                with self.assertRaises(bca.BuildError) as e: self.assemble()
                self.assertEqual(str(e.exception), f'{self.out} is not nxnative Converter ({why}) and is left as it is: give another place with -o')
                self.assertEqual(((self.out / 'Contents/keep').read_text(), [p.name for p in self.apps.iterdir()], list(self.bin.iterdir())), ('mine', [APP], []))
                shutil.rmtree(self.out)

    def test_swap_without_rename_swap(self):   # a volume without RENAME_SWAP (exFAT, SMB): the old app is set aside, then trashed
        self.assemble(count=1)
        libc = mock.Mock(); libc.renamex_np.return_value = -1
        with mock.patch.object(bca.ctypes, 'CDLL', return_value=libc), mock.patch.object(bca.ctypes, 'get_errno', return_value=bca.errno.ENOTSUP): self.assemble(count=2)
        self.assertEqual((self.version(), [p.name for p in self.apps.iterdir()]), ('2', [APP]))
        trashed, = self.bin.iterdir(); self.assertEqual(self.version(trashed), '1')
        libc.renamex_np.return_value = -1
        with mock.patch.object(bca.ctypes, 'CDLL', return_value=libc), mock.patch.object(bca.ctypes, 'get_errno', return_value=bca.errno.EIO):
            with self.assertRaises(OSError): self.assemble(count=3)   # any other error: nothing moved
        self.assertEqual((self.version(), [p.name for p in self.apps.iterdir()]), ('2', [APP]))

    def test_failure_keeps_the_old_app(self):
        self.assemble(count=1)
        self.binary.unlink()
        with self.assertRaises(OSError): self.assemble(count=2)
        self.assertEqual(self.version(), '1')
        self.assertEqual(([p.name for p in self.apps.iterdir()], list(self.bin.iterdir())), ([APP], []))

    @unittest.skipUnless(sys.platform == 'darwin' and shutil.which('codesign'), 'needs macOS (codesign)')
    def test_signed(self):
        self.assemble(identity='-')
        subprocess.run(['codesign', '--verify', '--strict', self.out], check=True, capture_output=True)
        d = subprocess.run(['codesign', '-dv', self.out], capture_output=True, text=True).stderr
        self.assertIn('Signature=adhoc', d); self.assertIn('Identifier=org.nxnative.converter', d)
        self.assertEqual(subprocess.run([self.out / 'Contents/MacOS/NXNativeConverter', 'x'], capture_output=True, text=True).stdout, 'converter x\n')


class Main(unittest.TestCase):
    def main(self, argv):
        err = io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()): code = bca.main(argv)
        return code, err.getvalue()

    def test_interrupted(self):
        with mock.patch.object(bca, 'build', side_effect=KeyboardInterrupt): self.assertEqual(self.main([]), (130, '[RED] interrupted\n'))

    @unittest.skipUnless(sys.platform == 'darwin', 'the script builds on a Mac only')
    def test_checks_before_the_build(self):   # one line, exit code 1, and swift never runs
        tmp = Path(tempfile.mkdtemp()).resolve(); self.addCleanup(shutil.rmtree, tmp)
        locked = tmp / 'locked'; locked.mkdir(); locked.chmod(0o555); self.addCleanup(locked.chmod, 0o755)
        with mock.patch.object(bca, 'run', side_effect=AssertionError('ran a tool')):
            code, err = self.main(['-o', str(tmp / 'Converter')])
            self.assertEqual((code, err), (1, f'[RED] the output must end in .app: {tmp / "Converter"}\n'))
            if os.access(locked, os.W_OK): self.skipTest('the folder stays writable (root)')
            code, err = self.main(['-o', str(locked / APP)])
            self.assertEqual(code, 1); self.assertIn(f'cannot write to {locked}', err); self.assertEqual(err.count('\n'), 1)
            with mock.patch.object(bca, 'DEFAULT_OUT', locked / APP):   # the default folder: the hint names ~/Applications
                code, err = self.main([])
            self.assertEqual(code, 1); self.assertIn('-o ~/Applications/nxnative\\ Converter.app', err)

    @unittest.skipUnless(sys.platform == 'darwin', 'the script builds on a Mac only')
    def test_refuses_another_app_before_the_build(self):
        tmp = Path(tempfile.mkdtemp()).resolve(); self.addCleanup(shutil.rmtree, tmp)
        other = tmp / 'Xcode.app'; (other / 'Contents').mkdir(parents=True)
        (other / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.apple.dt.Xcode'}))
        with mock.patch.object(bca, 'run', side_effect=AssertionError('ran a tool')): code, err = self.main(['-o', str(other)])
        self.assertEqual((code, err), (1, f'[RED] {other} is not nxnative Converter (its bundle ID is com.apple.dt.Xcode) and is left as it is: give another place with -o\n'))
        self.assertEqual(sorted(str(p.relative_to(tmp)) for p in tmp.rglob('*')), ['Xcode.app', 'Xcode.app/Contents', 'Xcode.app/Contents/Info.plist'])


if __name__ == '__main__':
    unittest.main()
