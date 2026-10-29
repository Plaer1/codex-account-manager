#!/usr/bin/python3
"""Linux desktop and tray interface for Codex Account Manager."""
import os
import re
import json
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse
from PySide6.QtCore import Qt, QThread, Signal, QProcess, QProcessEnvironment, QTimer, QSettings
from PySide6.QtGui import QAction, QIcon, QCursor
from PySide6.QtWidgets import (QApplication, QFileDialog, QFrame, QGridLayout, QHBoxLayout,
    QInputDialog, QLabel, QMainWindow, QMenu, QMessageBox, QPushButton, QScrollArea, QProgressBar,
    QSystemTrayIcon, QVBoxLayout, QWidget, QDialog, QTextEdit, QComboBox, QLineEdit, QCheckBox)
import linux_services as services

ROOT = Path(__file__).resolve().parent
SWITCHER = ROOT / 'codex-account-switcher.sh'
ICON = ROOT / 'resources' / 'AppIconClanked.png'

def timestamp_text(value, pattern='%b %d %H:%M', fallback='—'):
    if not isinstance(value, (int, float)): return fallback
    try: return datetime.fromtimestamp(value).strftime(pattern)
    except (ValueError, OverflowError, OSError): return fallback

class Worker(QThread):
    result = Signal(object)
    def __init__(self, fn):
        super().__init__(); self.fn = fn
    def run(self):
        try: self.result.emit(self.fn())
        except Exception as exc: self.result.emit({'error': str(exc)})

class HoverButton(QPushButton):
    hovered = Signal()
    unhovered = Signal()
    def enterEvent(self, event):
        self.hovered.emit(); super().enterEvent(event)
    def leaveEvent(self, event):
        self.unhovered.emit(); super().leaveEvent(event)

class Manager(QMainWindow):
    def __init__(self):
        super().__init__()
        self.quitting = False
        self.setWindowTitle('Codex Account Manager')
        self.setWindowIcon(QIcon(str(ICON)))
        self.resize(780, 590)
        self.setMinimumSize(520, 420)
        self.settings = QSettings('Plaer1', 'CodexAccountManager')
        self.snapshots = services.load_usage_cache(self.store_path()); self.workers = []
        self.privacy = self.settings.value('privacy', False, type=bool); self.login_process = None
        self.profiles = []; self.active = ''; self.popup = None
        self.profile_validity = {}; self.indicator_process = None; self.indicator_ready = False; self.indicator_buffer = ''
        base = QWidget(objectName='base'); self.setCentralWidget(base)
        outer = QVBoxLayout(base); outer.setContentsMargins(18,16,18,14); outer.setSpacing(12)
        bar = QHBoxLayout(); outer.addLayout(bar)
        title = QLabel('Codex Accounts', objectName='title'); font = title.font(); font.setBold(True); font.setPointSize(font.pointSize()+3); title.setFont(font); bar.addWidget(title); bar.addStretch()
        self.button(bar, 'Add account', lambda: self.start_login(), accent=True, icon='list-add')
        self.button(bar, 'Capture current', self.capture, icon='document-save')
        self.button(bar, 'Refresh', lambda: self.refresh(), icon='view-refresh')
        options = QPushButton('Options'); options_menu = QMenu(options)
        options_menu.addAction('Import auth.json…', self.import_account)
        options_menu.addAction('Toggle privacy', self.toggle_privacy)
        options_menu.addAction('Open profiles folder', lambda: self.run('open-folder'))
        options.setMenu(options_menu); bar.addWidget(options)
        self.summary = QLabel('', objectName='muted'); outer.addWidget(self.summary)
        scroll = QScrollArea(); scroll.setWidgetResizable(True); outer.addWidget(scroll,1)
        self.cards = QWidget(objectName='base'); self.grid = QGridLayout(self.cards)
        self.grid.setContentsMargins(0,0,0,0); self.grid.setSpacing(12); self.grid.setAlignment(Qt.AlignmentFlag.AlignTop)
        scroll.setWidget(self.cards)
        self.status = QLabel('Ready', objectName='muted'); outer.addWidget(self.status)
        self.tray = QSystemTrayIcon(QIcon(str(ICON)), self)
        self.tray.setToolTip('Codex Account Manager')
        self.tray.activated.connect(self.tray_activated)
        self.tray_menu = QMenu(); self.tray_menu.setToolTipsVisible(True); self.tray.setContextMenu(self.tray_menu)
        if QApplication.platformName().startswith('wayland') and 'KDE' in os.environ.get('XDG_CURRENT_DESKTOP', '').upper():
            self.start_indicator()
        elif QSystemTrayIcon.isSystemTrayAvailable(): self.tray.show()
        else: self.status.setText('System tray unavailable in this desktop session.')
        self.refresh()
        self.timer = QTimer(self); self.timer.timeout.connect(self.refresh); self.timer.start(60000)

    def button(self, layout, label, callback, accent=False, icon=None):
        b = QPushButton(label); b.clicked.connect(callback)
        if accent: b.setDefault(True)
        if icon: b.setIcon(QIcon.fromTheme(icon))
        layout.addWidget(b); return b

    def start_indicator(self):
        process = QProcess(self); self.indicator_process = process
        environment = QProcessEnvironment.systemEnvironment(); environment.insert('PYTHONUNBUFFERED', '1')
        process.setProcessEnvironment(environment)
        process.readyReadStandardOutput.connect(self.read_indicator)
        process.readyReadStandardError.connect(lambda: process.readAllStandardError())
        process.finished.connect(self.indicator_finished)
        process.errorOccurred.connect(lambda error: self.indicator_finished() if error == QProcess.ProcessError.FailedToStart else None)
        process.start(sys.executable, [str(ROOT / 'tray-indicator.py'), str(ICON)])

    def read_indicator(self):
        self.indicator_buffer += bytes(self.indicator_process.readAllStandardOutput()).decode('utf-8', 'replace')
        while '\n' in self.indicator_buffer:
            line, self.indicator_buffer = self.indicator_buffer.split('\n', 1)
            try: message = json.loads(line)
            except ValueError: continue
            action = message.get('action')
            if action == 'ready': self.indicator_ready = True; self.tray.hide(); self.update_indicator()
            elif action == 'open': self.show_manager()
            elif action == 'refresh': self.refresh()
            elif action == 'add': self.show_manager(); self.start_login()
            elif action == 'capture': self.show_manager(); self.capture()
            elif action == 'activate' and message.get('profile') in self.profiles:
                self.activate(message['profile'])
            elif action == 'quit': self.quit_app()

    def indicator_finished(self, *_args):
        self.indicator_ready = False
        if not self.quitting:
            if QSystemTrayIcon.isSystemTrayAvailable(): self.tray.show()
            self.status.setText('Native KDE tray unavailable; using the standard tray.')

    def update_indicator(self):
        if not self.indicator_ready or not self.indicator_process: return
        profiles = []
        for index, name in enumerate(self.profiles):
            snapshot = self.snapshots.get(name, {})
            display = f'Profile {index + 1}' if self.privacy else (services.nickname(self.store_path() / 'profiles' / name) or name)
            profiles.append({'name': name, 'display': display, 'active': name == self.active,
                'valid': self.profile_validity.get(name, False), 'windows': snapshot.get('windows', []),
                'stale': bool(snapshot.get('stale') or snapshot.get('recorded')), 'error': snapshot.get('error', '')})
        payload = json.dumps({'type': 'state', 'profiles': profiles}, ensure_ascii=True) + '\n'
        self.indicator_process.write(payload.encode('utf-8'))

    def run(self, *args, quiet=False):
        try: result = subprocess.run([str(SWITCHER), *args], capture_output=True, text=True)
        except OSError as exc:
            if not quiet: QMessageBox.critical(self, 'Account manager', str(exc))
            return None
        if result.returncode:
            if not quiet: QMessageBox.warning(self, 'Unable to complete action', result.stderr.strip() or 'Operation failed.')
            return None
        if not quiet: self.status.setText(result.stderr.strip() or 'Done')
        return result.stdout.strip()

    def refresh(self, fetch=True):
        names = self.run('list','--plain',quiet=True)
        if names is None:
            self.status.setText('Could not load profiles.'); return
        profiles = [x for x in names.splitlines() if x]
        active = self.run('verified-active',quiet=True) or ''
        self.profiles = profiles; self.active = active; self.profile_validity = {}
        state = self.run('active-state',quiet=True) or ''
        self.summary.setText(f'● Active: {("Hidden" if self.privacy else active) or "None"}     ● Desktop state: {("Hidden" if self.privacy else state) or "None"}')
        while self.grid.count():
            item = self.grid.takeAt(0)
            if item.widget(): item.widget().deleteLater()
        if not profiles:
            empty = QLabel('No saved profiles\n\nCapture the currently signed-in account to get started.')
            empty.setAlignment(Qt.AlignmentFlag.AlignCenter); empty.setMinimumHeight(220)
            empty.setObjectName('muted'); self.grid.addWidget(empty,0,0,1,2)
        for index, name in enumerate(profiles):
            profile = self.store_path() / 'profiles' / name
            card = QFrame(objectName='card'); card.setFrameShape(QFrame.Shape.StyledPanel); box = QVBoxLayout(card); box.setContentsMargins(16,14,16,14); box.setSpacing(10)
            heading = QHBoxLayout(); label = QLabel(f'Profile {index + 1}' if self.privacy else (services.nickname(profile) or name), objectName='profile'); font = label.font(); font.setBold(True); label.setFont(font); heading.addWidget(label); heading.addStretch()
            if name == active: heading.addWidget(QLabel('● Active'))
            box.addLayout(heading)
            meta = services.metadata(profile / 'auth' / 'auth.json')
            valid = self.run('profile-valid', name, quiet=True) is not None
            self.profile_validity[name] = valid
            identity = ('••••••' if self.privacy and meta['email'] else meta['email'])
            health = 'Missing auth' if not meta['has_auth'] else ('Identity mismatch' if not valid else ('Access expired' if isinstance(meta['expires'], (int,float)) and meta['expires'] <= time.time() else ''))
            details = QLabel(' · '.join(x for x in (identity, meta['plan'], health, 'Desktop state saved' if (profile / 'app-support' / 'Codex').is_dir() else '') if x) or 'Account profile')
            details.setObjectName('muted'); box.addWidget(details)
            snapshot = self.snapshots.get(name, {})
            if snapshot.get('windows'):
                if snapshot.get('stale') or snapshot.get('recorded'):
                    observed = timestamp_text(snapshot.get('observed'), fallback='unknown time')
                    box.addWidget(QLabel(f'Recorded usage · {observed}'))
                for window in snapshot['windows']:
                    caption = '7-day' if window['seconds'] >= 86400 else '5-hour'
                    reset = timestamp_text(window.get('reset'))
                    quota = QLabel(f"{caption}: {window['left']:.0f}% remaining · resets {reset}"); box.addWidget(quota)
                    progress = QProgressBar(); progress.setRange(0,100); progress.setValue(int(window['left'])); progress.setTextVisible(False); box.addWidget(progress)
            else:
                box.addWidget(QLabel(snapshot.get('error', 'Usage not loaded')))
            actions = QHBoxLayout(); box.addLayout(actions)
            self.button(actions,'Make active',lambda _=False,n=name: self.activate(n),True).setEnabled(name != active and valid)
            self.button(actions,'Desktop state',lambda _=False,n=name: self.action('make-state',n)).setEnabled((profile / 'app-support' / 'Codex').is_dir() and name != state and valid)
            more = QPushButton('⋯'); menu = QMenu(more)
            for label, fn in [('Re-authenticate',lambda _=False,n=name:self.start_login(n)),('Update auth from current login',lambda _=False,n=name:self.action('save-auth',n)),('Set nickname',lambda _=False,n=name:self.set_nickname(n)),('Account details',lambda _=False,n=name:self.details(n)),('Token vault',lambda _=False,n=name:self.token_vault(n)),('Rename',lambda _=False,n=name:self.rename(n)),('Export backup',lambda _=False,n=name:self.export(n)),('Delete',lambda _=False,n=name:self.delete(n))]:
                act = QAction(label,menu); act.triggered.connect(fn); menu.addAction(act)
            more.setMenu(menu); actions.addWidget(more)
            self.grid.addWidget(card,index//2,index%2)
        self.tray_menu.clear()
        self.tray_menu.addAction('Open Manager', self.show_manager)
        self.tray_menu.addAction('Refresh', lambda: self.refresh())
        if profiles: self.tray_menu.addSeparator()
        for index, name in enumerate(profiles):
            snapshot = self.snapshots.get(name, {}); windows = snapshot.get('windows', [])
            quota = ' · ' + ' / '.join(f"{w['left']:.0f}%" for w in windows) if windows else ''
            display = f'Profile {index + 1}' if self.privacy else (services.nickname(self.store_path() / 'profiles' / name) or name)
            action = self.tray_menu.addAction(('✓ ' if name == active else '') + display + quota)
            if windows and any(w['left'] <= 20 for w in windows): action.setIcon(QIcon.fromTheme('dialog-warning'))
            if windows:
                def tooltip(w):
                    reset = timestamp_text(w.get('reset'), fallback='unknown')
                    return f"{'7-day' if w['seconds'] >= 86400 else '5-hour'}: {w['left']:.0f}% remaining · resets {reset}"
                action.setToolTip('\n'.join(tooltip(w) for w in windows))
            action.setEnabled(name != active)
            action.triggered.connect(lambda _=False,n=name:self.activate(n))
        self.tray_menu.addSeparator(); self.tray_menu.addAction('Quit',self.quit_app)
        self.update_indicator()
        if fetch and profiles and not any(w.isRunning() for w in self.workers):
            paths = {name: (Path(os.environ.get('CODEX_AUTH_FILE') or Path.home()/'.codex/auth.json') if name == active else self.store_path() / 'profiles' / name / 'auth' / 'auth.json') for name in profiles}
            roots = {name: (Path.home() / '.codex' if name == active else self.store_path() / 'profiles' / name / 'app-support' / 'Codex') for name in profiles}
            marker = self.store_path() / 'active-profile'
            try: active_since = marker.stat().st_mtime
            except OSError: active_since = time.time()
            def load_usage():
                def load_one(name):
                    path = paths[name]
                    current = services.usage(path)
                    if current.get('error'):
                        recorded = services.local_usage(roots[name], active_since if name == active else 0)
                        if recorded.get('windows'): current = recorded
                    return name, current
                with ThreadPoolExecutor(max_workers=min(4, len(paths))) as pool:
                    return dict(pool.map(load_one, paths))
            self.run_worker(load_usage, self.usage_ready)

    def run_worker(self, fn, callback):
        worker = Worker(fn); self.workers.append(worker); worker.result.connect(callback)
        worker.finished.connect(lambda: self.worker_finished(worker))
        worker.start()
    def worker_finished(self, worker):
        if worker in self.workers: self.workers.remove(worker)
        if self.quitting and not self.workers: self.tray.hide(); QApplication.quit()
    def usage_ready(self, result):
        if isinstance(result, dict) and 'error' not in result:
            for name, snapshot in result.items():
                if snapshot.get('error') and self.snapshots.get(name, {}).get('windows'):
                    snapshot = dict(self.snapshots[name], stale=True, error=snapshot['error'])
                self.snapshots[name] = snapshot
            try: services.save_usage_cache(self.store_path(), self.snapshots)
            except OSError: self.status.setText('Could not save the usage cache.')
            self.refresh(fetch=False)
    def toggle_privacy(self):
        self.privacy = not self.privacy; self.settings.setValue('privacy', self.privacy); self.refresh(fetch=False)
    def set_nickname(self, name):
        profile = self.store_path() / 'profiles' / name
        value, ok = QInputDialog.getText(self, 'Nickname', 'Display name (leave blank to use profile name):', text=services.nickname(profile))
        if ok:
            try: services.set_nickname(profile, value.strip()); self.refresh(fetch=False)
            except (OSError, ValueError) as exc: QMessageBox.warning(self, 'Nickname', str(exc))
    def details(self, name):
        profile = self.store_path() / 'profiles' / name; meta = services.metadata(profile / 'auth' / 'auth.json')
        email = 'Hidden' if self.privacy else (meta['email'] or 'Unavailable')
        hidden = lambda value: ('Hidden' if self.privacy and value else (value or 'Unavailable'))
        expires = timestamp_text(meta['expires'], '%b %d %Y %H:%M', 'Unavailable')
        statuses = '\n'.join(services.token_statuses(profile / 'auth' / 'auth.json'))
        QMessageBox.information(self, 'Account details', f"Profile: {hidden(name)}\nEmail: {email}\nPlan: {meta['plan'] or 'Unavailable'}\nWorkspace: {hidden(meta['workspace'])}\nWorkspace ID: {hidden(meta['workspace_id'])}\nSeat: {meta['seat'] or 'Unavailable'}\nUser ID: {hidden(meta['subject'])}\nAccount ID: {hidden(meta['account'])}\nAuth mode: {meta['auth_mode'] or 'Unavailable'}\nAuth: {'Saved' if meta['has_auth'] else 'Missing'}\nAccess expires: {expires}\nLast refreshed: {meta['last_refresh'] or 'Unavailable'}\n\n{statuses}")
    def token_vault(self, name):
        auth = services.read_auth(self.store_path() / 'profiles' / name / 'auth' / 'auth.json')
        token_map = auth.get('tokens') if isinstance(auth.get('tokens'), dict) else {}
        tokens = {k: v for k, v in token_map.items() if isinstance(v, str) and v}
        if auth.get('OPENAI_API_KEY'): tokens['OPENAI_API_KEY'] = auth['OPENAI_API_KEY']
        if not tokens:
            QMessageBox.information(self, 'Token vault', 'No saved tokens are available.'); return
        dialog = QDialog(self); dialog.setWindowTitle(f'Token vault — {name}'); dialog.resize(560,160)
        layout = QVBoxLayout(dialog); selector = QComboBox(); selector.addItems(sorted(tokens)); layout.addWidget(selector)
        value = QLineEdit(); value.setReadOnly(True); value.setEchoMode(QLineEdit.EchoMode.Password); layout.addWidget(value)
        reveal = QCheckBox('Show token'); layout.addWidget(reveal)
        reveal.toggled.connect(lambda visible: value.setEchoMode(QLineEdit.EchoMode.Normal if visible else QLineEdit.EchoMode.Password))
        selector.currentTextChanged.connect(lambda key: value.setText(tokens[key]))
        value.setText(tokens[selector.currentText()])
        copy = QPushButton('Copy token'); copy.clicked.connect(lambda: QApplication.clipboard().setText(value.text())); layout.addWidget(copy)
        dialog.exec()

    def store_path(self):
        return Path(os.environ.get('SWITCHER_HOME') or (Path(os.environ.get('XDG_DATA_HOME') or Path.home()/'.local/share')/'CodexAccountSwitcher'))
    def import_account(self):
        path, _ = QFileDialog.getOpenFileName(self, 'Import auth.json', str(Path.home()), 'JSON files (*.json)')
        if path:
            name, accepted = QInputDialog.getText(self, 'Import account', 'Profile name:')
            if accepted and name.strip(): self.action('import-auth', name.strip(), path)

    def name_for_login(self, auth_path):
        meta = services.metadata(auth_path)
        email = meta['email'] if isinstance(meta['email'], str) else ''
        account = meta['account'] if isinstance(meta['account'], str) else ''
        candidate = (email.split('@')[0] if email else account[:12]) or 'codex'
        base = re.sub(r'[^a-z0-9._-]+', '-', candidate.lower()).strip('.-_') or 'codex'
        if not base[0].isalnum(): base = 'codex-' + base
        profiles = self.store_path() / 'profiles'; name = base; suffix = 2
        while (profiles / name).exists():
            name = f'{base}-{suffix}'; suffix += 1
        return name

    def start_login(self, target=None):
        if self.login_process is not None:
            QMessageBox.information(self, 'Sign in', 'A sign-in is already in progress.'); return
        executable = shutil.which('codex') or '/usr/lib/chatgpt/resources/codex'
        if not os.path.isfile(executable) or not os.access(executable, os.X_OK):
            QMessageBox.warning(self, 'Sign in', 'Codex CLI was not found. Install it or add it to PATH.'); return
        login_root = self.store_path() / 'managed-logins'; login_root.mkdir(mode=0o700, parents=True, exist_ok=True)
        home = Path(tempfile.mkdtemp(prefix='login-', dir=login_root)); os.chmod(home, 0o700)
        dialog = QDialog(self); dialog.setWindowTitle('Codex sign in'); dialog.resize(600,300)
        layout = QVBoxLayout(dialog); layout.addWidget(QLabel('Opening your browser for Codex sign-in. If it does not open, use the button below.'))
        open_browser = QPushButton('Open sign-in page'); open_browser.setEnabled(False); layout.addWidget(open_browser)
        copy_link = QPushButton('Copy sign-in link'); copy_link.setEnabled(False); layout.addWidget(copy_link)
        output = QTextEdit(); output.setReadOnly(True); output.document().setMaximumBlockCount(1000); output.hide(); layout.addWidget(output)
        details = QPushButton('Show sign-in details'); details.setCheckable(True)
        details.toggled.connect(lambda checked: (output.setVisible(checked), details.setText('Hide sign-in details' if checked else 'Show sign-in details')))
        layout.addWidget(details)
        cancel = QPushButton('Cancel'); layout.addWidget(cancel)
        proc = QProcess(self); self.login_process = proc
        login_timer = QTimer(proc); login_timer.setSingleShot(True); login_timer.timeout.connect(proc.kill)
        env = QProcessEnvironment.systemEnvironment(); env.insert('CODEX_HOME', str(home)); env.remove('BROWSER')
        proc.setProcessEnvironment(env); proc.setProcessChannelMode(QProcess.ProcessChannelMode.MergedChannels)
        browser = {'url': None, 'pending': '', 'cancelled': False}
        def open_login_url():
            if not browser['url']: return
            opener = shutil.which('xdg-open')
            environment = os.environ.copy(); environment.pop('BROWSER', None)
            try:
                if not opener: raise FileNotFoundError('xdg-open not found')
                subprocess.Popen([opener, browser['url']], env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            except OSError:
                QMessageBox.warning(dialog, 'Browser', 'Could not open the browser. Copy the sign-in link and open it manually on this computer.')
        open_browser.clicked.connect(open_login_url)
        copy_link.clicked.connect(lambda: QApplication.clipboard().setText(browser['url']) if browser['url'] else None)
        def read_output():
            text = bytes(proc.readAllStandardOutput()).decode('utf-8', 'replace')
            output.insertPlainText(text); browser['pending'] += text
            lines = browser['pending'].split('\n'); browser['pending'] = lines.pop()[-8192:]
            for line in lines:
                for match in re.findall(r'https?://[^\s<>"\']+', line):
                    url = match.rstrip('.,);]')
                    try: parsed = urlparse(url); hostname = parsed.hostname
                    except ValueError: continue
                    if parsed.scheme == 'https' and hostname in ('auth.openai.com', 'chatgpt.com'):
                        if browser['url'] is None:
                            browser['url'] = url; open_browser.setEnabled(True); copy_link.setEnabled(True)
                        return
        proc.readyReadStandardOutput.connect(read_output)
        def cancel_login(): browser['cancelled'] = True; proc.kill()
        cancel.clicked.connect(cancel_login)
        dialog.rejected.connect(cancel_login)
        def finished(code, _status):
            if self.login_process is not proc: return
            login_timer.stop(); self.login_process = None; dialog.accept()
            if self.quitting: return
            if browser['cancelled']:
                self.status.setText(f'Sign-in cancelled; temporary files retained at {home}'); return
            if code != 0 or _status != QProcess.ExitStatus.NormalExit or not (home / 'auth.json').is_file():
                detail = re.sub(r'https?://\S+', '[sign-in link]', output.toPlainText()).strip()[-1800:]
                QMessageBox.warning(self, 'Sign in', f'Sign-in did not finish. Login files retained at {home}\n\n{detail}'); return
            if target:
                self.status.setText('Verifying the new login…')
                self.run_worker(lambda: services.validate(home / 'auth.json'), lambda result: self.finish_reauth(target, home, result))
            elif self.run('import-home', self.name_for_login(home / 'auth.json'), str(home)) is not None:
                shutil.rmtree(home); self.refresh()
            else:
                QMessageBox.warning(self, 'Sign in', f'Login files retained at {home}')
        proc.finished.connect(finished)
        def process_error(error):
            if error == QProcess.ProcessError.FailedToStart:
                self.login_process = None; dialog.accept()
                QMessageBox.warning(self, 'Sign in', f'Could not start the Codex CLI. Login files retained at {home}')
        proc.errorOccurred.connect(process_error)
        proc.start(executable, ['-c', 'cli_auth_credentials_store="file"', 'login'])
        login_timer.start(180000)
        dialog.open()

    def finish_reauth(self, name, home, result):
        if not isinstance(result, dict) or not result.get('ok'):
            reason = result.get('error', 'Login could not be verified.') if isinstance(result, dict) else 'Login could not be verified.'
            QMessageBox.warning(self, 'Re-authentication', f'{reason}\nFresh login retained at {home}'); return
        if self.run('replace-auth', name, str(home)) is not None:
            saved = self.store_path() / 'profiles' / name / 'auth' / 'auth.json'
            try: installed = saved.read_bytes() == (home / 'auth.json').read_bytes()
            except OSError: installed = False
            if installed:
                shutil.rmtree(home); self.refresh(); return
        QMessageBox.warning(self, 'Re-authentication', f'The login was not verified as installed. Fresh login retained at {home}')

    def action(self, command, name, *args):
        if self.run(command,name,*args) is not None: self.refresh()
    def activate(self,name): self.action('make-active',name)
    def capture(self):
        name, ok = QInputDialog.getText(self,'Capture account','Close Codex first, then enter a profile name:')
        if ok and name.strip(): self.action('capture',name.strip())
    def rename(self,name):
        new,ok = QInputDialog.getText(self,'Rename profile','New profile name:',text=name)
        if ok and new.strip():
            if self.run('rename',name,new.strip()) is not None:
                if name in self.snapshots: self.snapshots[new.strip()] = self.snapshots.pop(name)
                try: services.save_usage_cache(self.store_path(), self.snapshots)
                except OSError: self.status.setText('Could not save the usage cache.')
                self.refresh()
    def export(self,name):
        path,_ = QFileDialog.getSaveFileName(self,'Export profile backup',str(Path.home()/f'{name}-codex-profile.zip'),'Zip archives (*.zip)')
        if path: self.run('export-profile',name,path)
    def delete(self,name):
        if QMessageBox.question(self,'Delete profile',f'Delete {name} and its saved auth and desktop state?') == QMessageBox.StandardButton.Yes:
            if self.run('delete',name) is not None:
                self.snapshots.pop(name, None)
                try: services.save_usage_cache(self.store_path(), self.snapshots)
                except OSError: self.status.setText('Could not save the usage cache.')
                self.refresh()
    def tray_activated(self,reason):
        if reason == QSystemTrayIcon.ActivationReason.Trigger: self.show_tray_popup()
        elif reason == QSystemTrayIcon.ActivationReason.DoubleClick: self.show_manager()

    def show_tray_popup(self):
        if self.popup and self.popup.isVisible(): self.popup.close(); return
        popup = QDialog(None, Qt.WindowType.Tool | Qt.WindowType.FramelessWindowHint | Qt.WindowType.WindowStaysOnTopHint)
        popup.setWindowTitle('Codex Accounts'); popup.setMinimumWidth(330)
        popup.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        popup.finished.connect(lambda _result: setattr(self, 'popup', None))
        self.popup = popup; layout = QVBoxLayout(popup); layout.setContentsMargins(14,14,14,14); layout.setSpacing(8)
        header = QHBoxLayout(); title = QLabel('Codex Accounts'); font = title.font(); font.setBold(True); title.setFont(font)
        header.addWidget(title); header.addStretch(); self.button(header, 'Refresh', lambda: (self.refresh(), popup.close()), icon='view-refresh')
        self.button(header, '×', popup.close); layout.addLayout(header)
        selected = {'name': self.active if self.active in self.profiles else (self.profiles[0] if self.profiles else '')}
        usage_title = QLabel(); layout.addWidget(usage_title)
        quota_box = QVBoxLayout(); layout.addLayout(quota_box)
        def update_usage(name):
            while quota_box.count():
                item = quota_box.takeAt(0)
                if item.widget(): item.widget().deleteLater()
            if not name:
                usage_title.setText('No saved profiles'); return
            display = 'Profile' if self.privacy else (services.nickname(self.store_path() / 'profiles' / name) or name)
            usage_title.setText(f'Usage · {display}')
            snapshot = self.snapshots.get(name, {}); windows = snapshot.get('windows', [])
            if not windows: quota_box.addWidget(QLabel(snapshot.get('error', 'Usage not loaded'))); return
            if snapshot.get('stale') or snapshot.get('recorded'): quota_box.addWidget(QLabel('Recorded usage'))
            for window in windows:
                reset = timestamp_text(window.get('reset'))
                caption = '7-day' if window['seconds'] >= 86400 else '5-hour'
                quota_box.addWidget(QLabel(f"{caption}: {window['left']:.0f}% remaining · resets {reset}"))
                bar = QProgressBar(); bar.setRange(0,100); bar.setValue(int(window['left'])); bar.setTextVisible(False); quota_box.addWidget(bar)
        buttons = []
        def select(name):
            selected['name'] = name
            for button, profile in buttons: button.setChecked(profile == name)
            update_usage(name)
        for index, name in enumerate(self.profiles):
            display = f'Profile {index + 1}' if self.privacy else (services.nickname(self.store_path() / 'profiles' / name) or name)
            button = HoverButton(('✓ ' if name == self.active else '') + display); button.setCheckable(True)
            button.setChecked(name == selected['name']); button.clicked.connect(lambda _=False,n=name: select(n))
            button.hovered.connect(lambda n=name: update_usage(n)); button.unhovered.connect(lambda: update_usage(selected['name']))
            layout.addWidget(button); buttons.append((button,name))
        actions = QHBoxLayout(); layout.addLayout(actions)
        def activate_selected():
            name = selected['name']; popup.close()
            if name and name != self.active: self.activate(name)
        self.button(actions, 'Make active', activate_selected, accent=True)
        self.button(actions, 'Open Manager', lambda: (popup.close(), self.show_manager()))
        self.button(actions, 'Quit', self.quit_app)
        update_usage(selected['name']); popup.adjustSize()
        screen = QApplication.screenAt(QCursor.pos()) or QApplication.primaryScreen()
        bounds = screen.availableGeometry(); point = QCursor.pos()
        x = max(bounds.left(), min(point.x() - popup.width() // 2, bounds.right() - popup.width()))
        y = max(bounds.top(), min(point.y() - popup.height(), bounds.bottom() - popup.height()))
        popup.move(x,y); popup.show(); popup.raise_(); popup.activateWindow()
    def show_manager(self): self.showNormal(); self.raise_(); self.activateWindow()
    def quit_app(self):
        self.quitting = True
        self.timer.stop()
        if self.login_process: self.login_process.kill(); self.login_process.waitForFinished(1000)
        if self.indicator_process and self.indicator_process.state() != QProcess.ProcessState.NotRunning:
            self.indicator_process.write(b'{"type":"shutdown"}\n'); self.indicator_process.waitForFinished(1500)
            if self.indicator_process.state() != QProcess.ProcessState.NotRunning:
                self.indicator_process.kill(); self.indicator_process.waitForFinished(1000)
        self.indicator_ready = False
        if self.workers: self.hide(); self.tray.setToolTip('Finishing account requests…')
        else: self.tray.hide(); QApplication.quit()
    def closeEvent(self,event):
        if not self.quitting and (self.indicator_ready or self.tray.isVisible()): self.hide(); event.ignore()
        elif self.workers: event.ignore(); self.quit_app()
        else: event.accept()

def main():
    app=QApplication(sys.argv); app.setApplicationName('Codex Account Manager'); app.setDesktopFileName('codex-account-manager'); app.setQuitOnLastWindowClosed(True)
    window=Manager(); window.show(); return app.exec()
if __name__ == '__main__': raise SystemExit(main())
