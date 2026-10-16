from __future__ import annotations

import logging
import os
import sys
import time
import ctypes
from ctypes import wintypes
from pathlib import Path
from queue import Empty, Queue
from threading import Thread

from .audio import AudioPlayer
from .engine import SpeechEngine
from .events import EventBus
from .models import VoiceAlias
from .protocol import SpeakerBotProtocol
from .server import BridgeServers
from .settings import Settings, default_config_dir
from .voicestudio import VoiceStudioClient
from .streamerbot import StreamerBotActions
from .obs import ObsDucking
from .channel import instance_name


def acquire_backend_mutex():
    """Allow only one playback backend per Windows user session."""
    if sys.platform != "win32":
        return True
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.CreateMutexW.argtypes = (wintypes.LPVOID, wintypes.BOOL, wintypes.LPCWSTR)
    kernel32.CreateMutexW.restype = wintypes.HANDLE
    handle = kernel32.CreateMutexW(None, False, instance_name("Backend"))
    if not handle:
        raise ctypes.WinError()
    if ctypes.get_last_error() == 183:  # ERROR_ALREADY_EXISTS
        kernel32.CloseHandle(handle)
        return None
    return handle


def release_backend_mutex(handle) -> None:
    if sys.platform == "win32" and handle not in (None, True):
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.ReleaseMutex(wintypes.HANDLE(handle))
        kernel32.CloseHandle(wintypes.HANDLE(handle))


def wait_for_desktop_exit() -> None:
    """Stop cleanly when the desktop asks, or if its owning process disappears."""
    if sys.platform != "win32":
        while True:
            time.sleep(1)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.CreateEventW.argtypes = (wintypes.LPVOID, wintypes.BOOL, wintypes.BOOL, wintypes.LPCWSTR)
    kernel32.CreateEventW.restype = wintypes.HANDLE
    kernel32.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
    kernel32.OpenProcess.restype = wintypes.HANDLE
    signal = kernel32.CreateEventW(None, True, False, instance_name("BackendStop"))
    parent_pid = os.environ.get("VOXRELAY_PARENT_PID", "")
    parent = kernel32.OpenProcess(0x00100000, False, int(parent_pid)) if parent_pid else None
    try:
        if parent_pid and not parent:
            return
        while kernel32.WaitForSingleObject(wintypes.HANDLE(signal), 500) == 258:
            if parent and kernel32.WaitForSingleObject(wintypes.HANDLE(parent), 0) == 0:
                return
    finally:
        if signal:
            kernel32.CloseHandle(wintypes.HANDLE(signal))
        if parent:
            kernel32.CloseHandle(wintypes.HANDLE(parent))


class BridgeApp:
    COLORS = {
        "window": "#17131a",
        "panel": "#211b24",
        "panel_alt": "#2b222d",
        "input": "#352a37",
        "border": "#49384d",
        "text": "#f5edf7",
        "muted": "#b9aabd",
        "accent": "#8b4dd8",
        "accent_hover": "#a45def",
        "success": "#52c98b",
    }

    def __init__(self, root: tk.Tk):
        self.root = root
        self.root.title("VoxRelay")
        self.root.geometry("860x680")
        self.root.minsize(760, 590)
        self._configure_theme()
        self.settings = Settings()
        self.events = EventBus()
        self.engine = SpeechEngine(self.settings, self.events)
        self.protocol = SpeakerBotProtocol(self.settings, self.engine)
        self.servers = BridgeServers(self.settings, self.protocol, self.events)
        self.ui_queue: Queue[tuple[str, object]] = Queue()
        self.discovered_voices: list[dict] = []
        self.voice_name_by_id: dict[str, str] = {}
        self.voice_label_by_id: dict[str, str] = {}
        self.voice_id_by_label: dict[str, str] = {}
        self.voice_selectors: list[ttk.Combobox] = []
        self.events.subscribe(self._event_received)
        self._build_ui()
        self._load_settings_into_ui()
        self.engine.start()
        self.servers.start()
        self.root.protocol("WM_DELETE_WINDOW", self.close)
        self.root.after(100, self._poll_ui_queue)
        self.root.after(300, self.refresh_voices)
        self._set_status("Bridge running; start VoiceStudio, then refresh voices")

    def _configure_theme(self) -> None:
        c = self.COLORS
        self.root.configure(background=c["window"])
        style = ttk.Style(self.root)
        style.theme_use("clam")
        style.configure(".", background=c["window"], foreground=c["text"], font=("Segoe UI", 10))
        style.configure("TFrame", background=c["window"])
        style.configure("Panel.TFrame", background=c["panel"])
        style.configure("Header.TFrame", background=c["window"])
        style.configure("TLabel", background=c["window"], foreground=c["text"])
        style.configure("Panel.TLabel", background=c["panel"], foreground=c["text"])
        style.configure("Muted.TLabel", background=c["window"], foreground=c["muted"])
        style.configure("Title.TLabel", background=c["window"], foreground=c["text"], font=("Segoe UI Semibold", 18))
        style.configure("Subtitle.TLabel", background=c["window"], foreground=c["muted"], font=("Segoe UI", 9))
        style.configure("Status.TLabel", background=c["panel"], foreground=c["success"], padding=(10, 7))
        style.configure("TLabelframe", background=c["panel"], bordercolor=c["border"], relief="solid")
        style.configure("TLabelframe.Label", background=c["window"], foreground=c["muted"], font=("Segoe UI Semibold", 9))
        style.configure("TEntry", fieldbackground=c["input"], foreground=c["text"], bordercolor=c["border"], insertcolor=c["text"], padding=7)
        style.configure("TSpinbox", fieldbackground=c["input"], foreground=c["text"], bordercolor=c["border"], arrowcolor=c["muted"], padding=6)
        style.configure("TCombobox", fieldbackground=c["input"], foreground=c["text"], background=c["input"], bordercolor=c["border"], arrowcolor=c["muted"], padding=6)
        style.map("TCombobox", fieldbackground=[("readonly", c["input"])], foreground=[("readonly", c["text"])])
        style.configure("TButton", background=c["panel_alt"], foreground=c["text"], bordercolor=c["border"], padding=(12, 8), font=("Segoe UI Semibold", 9))
        style.map("TButton", background=[("active", c["input"]), ("pressed", c["accent"])], bordercolor=[("focus", c["accent"])])
        style.configure("Accent.TButton", background=c["accent"], foreground="#ffffff", bordercolor=c["accent"], padding=(14, 8))
        style.map("Accent.TButton", background=[("active", c["accent_hover"]), ("pressed", c["accent"])])
        style.configure("TCheckbutton", background=c["window"], foreground=c["text"], indicatorcolor=c["input"], padding=4)
        style.map("TCheckbutton", background=[("active", c["window"])], indicatorcolor=[("selected", c["accent"])])
        style.configure("TNotebook", background=c["window"], borderwidth=0, tabmargins=(0, 6, 0, 0))
        style.configure("TNotebook.Tab", background=c["panel"], foreground=c["muted"], padding=(18, 9), borderwidth=0)
        style.map("TNotebook.Tab", background=[("selected", c["accent"]), ("active", c["panel_alt"])], foreground=[("selected", "#ffffff")])
        style.configure("Treeview", background=c["panel"], fieldbackground=c["panel"], foreground=c["text"], bordercolor=c["border"], rowheight=31)
        style.configure("Treeview.Heading", background=c["panel_alt"], foreground=c["text"], bordercolor=c["border"], padding=(8, 7), font=("Segoe UI Semibold", 9))
        style.map("Treeview", background=[("selected", c["accent"])], foreground=[("selected", "#ffffff")])

    def _build_ui(self) -> None:
        self.root.columnconfigure(0, weight=1)
        self.root.rowconfigure(2, weight=1)

        header = ttk.Frame(self.root, style="Header.TFrame", padding=(14, 12, 14, 6))
        header.grid(row=0, column=0, sticky="ew")
        header.columnconfigure(0, weight=1)
        ttk.Label(header, text="VoxRelay", style="Title.TLabel").grid(row=0, column=0, sticky="w")
        ttk.Label(header, text="Cloned voices for Streamer.bot - Speaker.bot stays independent", style="Subtitle.TLabel").grid(row=1, column=0, sticky="w", pady=(1, 0))

        connection = ttk.LabelFrame(self.root, text="VoiceStudio connection", padding=10)
        connection.grid(row=1, column=0, padx=14, pady=(6, 7), sticky="ew")
        connection.columnconfigure(1, weight=1)
        ttk.Label(connection, text="Address").grid(row=0, column=0, sticky="w")
        self.url_var = tk.StringVar()
        ttk.Entry(connection, textvariable=self.url_var).grid(row=0, column=1, padx=5, sticky="ew")
        ttk.Label(connection, text="API key").grid(row=1, column=0, sticky="w")
        self.key_var = tk.StringVar()
        ttk.Entry(connection, textvariable=self.key_var, show="*").grid(row=1, column=1, padx=5, sticky="ew")
        ttk.Button(connection, text="Refresh voices", command=self.refresh_voices, style="Accent.TButton").grid(
            row=0, column=2, rowspan=2, padx=(5, 0), sticky="ns"
        )

        main = ttk.Notebook(self.root)
        main.grid(row=2, column=0, padx=14, pady=5, sticky="nsew")

        aliases = ttk.Frame(main, padding=10)
        aliases.columnconfigure(0, weight=1)
        aliases.rowconfigure(0, weight=1)
        main.add(aliases, text="Voice aliases")
        self.alias_tree = ttk.Treeview(aliases, columns=("profile", "model", "speed"), show="headings")
        for column, title, width in (("profile", "VoiceStudio voice", 350), ("model", "Model", 130), ("speed", "Speed", 80)):
            self.alias_tree.heading(column, text=title)
            self.alias_tree.column(column, width=width)
        self.alias_tree.grid(row=0, column=0, columnspan=4, sticky="nsew")
        ttk.Button(aliases, text="Add", command=self.add_alias).grid(row=1, column=0, pady=8, sticky="ew")
        ttk.Button(aliases, text="Edit", command=self.edit_alias).grid(row=1, column=1, padx=5, pady=8, sticky="ew")
        ttk.Button(aliases, text="Remove", command=self.remove_alias).grid(row=1, column=2, pady=8, sticky="ew")
        ttk.Button(aliases, text="Test selected alias", command=self.test_alias, style="Accent.TButton").grid(row=1, column=3, padx=(5, 0), pady=8, sticky="ew")

        settings_tab = ttk.Frame(main, padding=10)
        settings_tab.columnconfigure(1, weight=1)
        main.add(settings_tab, text="Bridge settings")
        self.ws_port_var = tk.IntVar()
        self.http_port_var = tk.IntVar()
        self.udp_var = tk.BooleanVar()
        self.udp_port_var = tk.IntVar()
        self.device_var = tk.StringVar()
        self.limit_var = tk.IntVar()
        rows = [
            ("Optional Speaker.bot-style WebSocket port", ttk.Spinbox(settings_tab, from_=1, to=65535, textvariable=self.ws_port_var)),
            ("VoiceStudio action HTTP port", ttk.Spinbox(settings_tab, from_=1, to=65535, textvariable=self.http_port_var)),
            ("Maximum message characters", ttk.Spinbox(settings_tab, from_=1, to=4096, textvariable=self.limit_var)),
        ]
        for row, (label, widget) in enumerate(rows):
            ttk.Label(settings_tab, text=label).grid(row=row, column=0, padx=(0, 8), pady=6, sticky="w")
            widget.grid(row=row, column=1, pady=6, sticky="ew")
        ttk.Checkbutton(settings_tab, text="Enable Streamer.bot UDP action", variable=self.udp_var).grid(
            row=3, column=0, columnspan=2, pady=6, sticky="w"
        )
        ttk.Label(settings_tab, text="Streamer.bot UDP port").grid(row=4, column=0, padx=(0, 8), pady=6, sticky="w")
        ttk.Spinbox(settings_tab, from_=1, to=65535, textvariable=self.udp_port_var).grid(row=4, column=1, pady=6, sticky="ew")
        ttk.Label(settings_tab, text="Audio output").grid(row=5, column=0, padx=(0, 8), pady=6, sticky="w")
        self.device_combo = ttk.Combobox(settings_tab, textvariable=self.device_var, state="readonly")
        self.device_combo.grid(row=5, column=1, pady=6, sticky="ew")
        ttk.Button(settings_tab, text="Save settings", command=self.save_settings, style="Accent.TButton").grid(row=6, column=1, pady=12, sticky="e")
        ttk.Label(settings_tab, text="Keep Speaker.bot on port 7580. VoiceStudio actions use UDP port 6670.", style="Muted.TLabel").grid(
            row=7, column=0, columnspan=2, sticky="w"
        )

        log_frame = ttk.LabelFrame(self.root, text="Activity", padding=5)
        log_frame.grid(row=3, column=0, padx=14, pady=(7, 8), sticky="ew")
        self.activity = tk.Listbox(
            log_frame,
            height=6,
            background=self.COLORS["panel"],
            foreground=self.COLORS["muted"],
            selectbackground=self.COLORS["accent"],
            selectforeground="#ffffff",
            borderwidth=0,
            highlightthickness=0,
            font=("Cascadia Mono", 9),
        )
        self.activity.pack(fill="both", expand=True)
        self.status_var = tk.StringVar()
        ttk.Label(self.root, textvariable=self.status_var, anchor="w", style="Status.TLabel").grid(row=4, column=0, padx=14, pady=(0, 12), sticky="ew")

    def _load_settings_into_ui(self) -> None:
        self.url_var.set(self.settings.voice_studio_url)
        self.key_var.set(self.settings.api_key)
        self.ws_port_var.set(self.settings.ws_port)
        self.http_port_var.set(self.settings.http_port)
        self.udp_var.set(self.settings.enable_udp)
        self.udp_port_var.set(self.settings.udp_port)
        self.limit_var.set(self.settings.max_characters)
        devices = ["[Default]"] + AudioPlayer.list_devices()
        self.device_combo["values"] = devices
        self.device_var.set(self.settings.output_device or "[Default]")
        self._refresh_alias_tree()

    def _refresh_alias_tree(self) -> None:
        self.alias_tree.delete(*self.alias_tree.get_children())
        for name, alias in sorted(self.settings.aliases.items()):
            voice_name = self.voice_name_by_id.get(alias.voice_id, alias.voice_id)
            self.alias_tree.insert("", "end", iid=name, values=(voice_name, alias.model, alias.speed))

    def _client(self) -> VoiceStudioClient:
        return VoiceStudioClient(self.url_var.get().strip(), self.key_var.get().strip() or "local")

    def refresh_voices(self) -> None:
        self._set_status("Connecting to VoiceStudio...")
        def task():
            try:
                health = self._client().health()
                voices = self._client().list_voices()
                self.ui_queue.put(("voices", (health, voices)))
            except Exception as exc:
                self.ui_queue.put(("error", str(exc)))
        Thread(target=task, daemon=True).start()

    @staticmethod
    def _voice_id(voice: dict) -> str:
        return str(voice.get("voice_id") or voice.get("id") or voice.get("name") or "default")

    @staticmethod
    def _voice_label(voice: dict) -> str:
        voice_id = BridgeApp._voice_id(voice)
        name = str(voice.get("name") or voice.get("display_name") or voice_id)
        return f"{name}  [{voice_id}]" if name != voice_id else voice_id

    def _alias_dialog(self, existing: VoiceAlias | None = None) -> VoiceAlias | None:
        dialog = tk.Toplevel(self.root)
        dialog.title("Edit voice alias" if existing else "Add voice alias")
        dialog.configure(background=self.COLORS["window"])
        dialog.resizable(False, False)
        dialog.transient(self.root)
        dialog.grab_set()
        dialog.columnconfigure(1, weight=1)
        values = {
            "name": tk.StringVar(value=existing.name if existing else ""),
            "voice": tk.StringVar(value=(self.voice_label_by_id.get(existing.voice_id, existing.voice_id) if existing else "default")),
            "model": tk.StringVar(value=existing.model if existing else "tts-1"),
            "speed": tk.DoubleVar(value=existing.speed if existing else 1.0),
            "language": tk.StringVar(value=existing.language if existing else ""),
            "instruct": tk.StringVar(value=existing.instruct if existing else ""),
            "volume": tk.DoubleVar(value=existing.volume if existing else 1.0),
        }
        voice_labels = [self._voice_label(voice) for voice in self.discovered_voices]
        voice_selector = ttk.Combobox(dialog, textvariable=values["voice"], values=voice_labels, state="readonly")
        self.voice_selectors.append(voice_selector)
        fields = [
            ("Alias name", ttk.Entry(dialog, textvariable=values["name"])),
            ("VoiceStudio voice", voice_selector),
            ("Model", ttk.Combobox(dialog, textvariable=values["model"], values=("tts-1", "tts-1-hd", "omnivoice", "voxcpm2", "cosyvoice", "mlx-audio", "kittentts", "moss-tts-nano"))),
            ("Speed (0.25-4.0)", ttk.Spinbox(dialog, from_=0.25, to=4.0, increment=0.05, textvariable=values["speed"])),
            ("Volume (0-2.0)", ttk.Spinbox(dialog, from_=0.0, to=2.0, increment=0.05, textvariable=values["volume"])),
            ("Language code (optional)", ttk.Entry(dialog, textvariable=values["language"])),
            ("Style instruction (optional)", ttk.Entry(dialog, textvariable=values["instruct"])),
        ]
        for row, (label, widget) in enumerate(fields):
            ttk.Label(dialog, text=label).grid(row=row, column=0, padx=10, pady=5, sticky="w")
            widget.grid(row=row, column=1, padx=10, pady=5, sticky="ew")
        result: list[VoiceAlias] = []
        def save():
            name = values["name"].get().strip()
            if not name:
                messagebox.showerror("Invalid alias", "Alias name cannot be blank.", parent=dialog)
                return
            try:
                result.append(VoiceAlias(
                    name=name,
                    voice_id=self.voice_id_by_label.get(values["voice"].get().strip(), values["voice"].get().strip()) or "default",
                    model=values["model"].get().strip() or "tts-1",
                    speed=float(values["speed"].get()),
                    volume=float(values["volume"].get()),
                    language=values["language"].get().strip(),
                    instruct=values["instruct"].get().strip(),
                ))
            except (ValueError, tk.TclError):
                messagebox.showerror("Invalid values", "Speed or volume is invalid.", parent=dialog)
                return
            dialog.destroy()
        buttons = ttk.Frame(dialog)
        buttons.grid(row=len(fields), column=0, columnspan=2, padx=10, pady=10, sticky="e")
        ttk.Button(buttons, text="Cancel", command=dialog.destroy).pack(side="left", padx=5)
        ttk.Button(buttons, text="Save", command=save).pack(side="left")
        dialog.wait_window()
        if voice_selector in self.voice_selectors:
            self.voice_selectors.remove(voice_selector)
        return result[0] if result else None

    def add_alias(self) -> None:
        alias = self._alias_dialog()
        if alias:
            if alias.name in self.settings.aliases:
                messagebox.showerror("Duplicate alias", f"{alias.name} already exists.")
                return
            self.settings.aliases[alias.name] = alias
            self.settings.save()
            self._refresh_alias_tree()

    def edit_alias(self) -> None:
        selection = self.alias_tree.selection()
        if not selection:
            messagebox.showinfo("Select an alias", "Select an alias to edit.")
            return
        old_name = selection[0]
        alias = self._alias_dialog(self.settings.aliases[old_name])
        if alias:
            if alias.name != old_name and alias.name in self.settings.aliases:
                messagebox.showerror("Duplicate alias", f"{alias.name} already exists.")
                return
            del self.settings.aliases[old_name]
            self.settings.aliases[alias.name] = alias
            self.settings.save()
            self._refresh_alias_tree()

    def remove_alias(self) -> None:
        selection = self.alias_tree.selection()
        if selection and messagebox.askyesno("Remove alias", f"Remove {selection[0]}?"):
            del self.settings.aliases[selection[0]]
            self.settings.save()
            self._refresh_alias_tree()

    def test_alias(self) -> None:
        selection = self.alias_tree.selection()
        if not selection:
            messagebox.showinfo("Select an alias", "Select an alias to test.")
            return
        text = simpledialog.askstring("Test voice", "Text to speak:", initialvalue="VoxRelay is ready.")
        if text:
            try:
                self.engine.enqueue(text, self.settings.aliases[selection[0]])
            except ValueError as exc:
                messagebox.showerror("Cannot speak", str(exc))

    def save_settings(self) -> None:
        try:
            self.settings.voice_studio_url = self.url_var.get().strip().rstrip("/")
            self.settings.api_key = self.key_var.get().strip() or "local"
            self.settings.ws_port = int(self.ws_port_var.get())
            self.settings.http_port = int(self.http_port_var.get())
            self.settings.enable_udp = bool(self.udp_var.get())
            self.settings.udp_port = int(self.udp_port_var.get())
            self.settings.output_device = "" if self.device_var.get() == "[Default]" else self.device_var.get()
            self.settings.max_characters = int(self.limit_var.get())
            self.settings.save()
            self.engine.audio.output_device = self.settings.output_device
            self._set_status("Settings saved")
        except (ValueError, tk.TclError) as exc:
            messagebox.showerror("Invalid settings", str(exc))

    def _event_received(self, source: str, event_type: str, data: dict) -> None:
        self.ui_queue.put(("activity", f"{event_type}: {data.get('text', '')}"))

    def _poll_ui_queue(self) -> None:
        try:
            while True:
                event, payload = self.ui_queue.get_nowait()
                if event == "voices":
                    health, self.discovered_voices = payload
                    self.voice_name_by_id = {
                        self._voice_id(voice): str(voice.get("name") or voice.get("display_name") or self._voice_id(voice))
                        for voice in self.discovered_voices
                    }
                    self.voice_label_by_id = {
                        self._voice_id(voice): self._voice_label(voice)
                        for voice in self.discovered_voices
                    }
                    self.voice_id_by_label = {
                        self._voice_label(voice): self._voice_id(voice)
                        for voice in self.discovered_voices
                    }
                    voice_labels = list(self.voice_id_by_label)
                    for selector in list(self.voice_selectors):
                        try:
                            selector["values"] = voice_labels
                            current = selector.get().strip()
                            if current in self.voice_label_by_id:
                                selector.set(self.voice_label_by_id[current])
                            elif current == "default" and voice_labels:
                                profile_labels = [
                                    self._voice_label(voice)
                                    for voice in self.discovered_voices
                                    if voice.get("type") == "profile"
                                ]
                                selector.set(profile_labels[0] if profile_labels else voice_labels[0])
                        except tk.TclError:
                            self.voice_selectors.remove(selector)
                    self._refresh_alias_tree()
                    device = health.get("device", "ready") if isinstance(health, dict) else "ready"
                    self._set_status(f"Connected to VoiceStudio ({device}); found {len(self.discovered_voices)} voices")
                elif event == "error":
                    self._set_status(str(payload))
                    messagebox.showerror("VoiceStudio connection failed", str(payload))
                elif event == "activity":
                    self.activity.insert(0, str(payload))
                    if self.activity.size() > 100:
                        self.activity.delete(100, tk.END)
        except Empty:
            pass
        self.root.after(100, self._poll_ui_queue)

    def _set_status(self, text: str) -> None:
        self.status_var.set(text)

    def close(self) -> None:
        self.save_settings()
        self.servers.stop()
        self.engine.shutdown()
        self.root.destroy()


def main() -> None:
    log_dir = default_config_dir()
    log_dir.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(threadName)s: %(message)s",
        handlers=[logging.FileHandler(log_dir / "bridge.log", encoding="utf-8"), logging.StreamHandler()],
    )
    if "--headless" in sys.argv:
        instance_mutex = acquire_backend_mutex()
        if instance_mutex is None:
            logging.warning("Another VoxRelay backend is already running; exiting duplicate")
            return
        settings = Settings()
        events = EventBus()
        engine = SpeechEngine(settings, events)
        protocol = SpeakerBotProtocol(settings, engine)
        servers = BridgeServers(settings, protocol, events)
        streamerbot_actions = StreamerBotActions(settings, events)
        obs_ducking = ObsDucking(settings, events)
        obs_ducking.start()
        engine.start()
        servers.start()
        streamerbot_actions.start()
        logging.info("VoxRelay service started in headless mode")
        try:
            wait_for_desktop_exit()
        except KeyboardInterrupt:
            pass
        finally:
            servers.stop()
            engine.shutdown()
            obs_ducking.shutdown()
            streamerbot_actions.shutdown()
            release_backend_mutex(instance_mutex)
        return

    # The packaged desktop is WPF. Keep legacy source-only UI dependencies out
    # of the playback service and the Windows distribution.
    global tk, messagebox, simpledialog, ttk
    import tkinter as tk
    from tkinter import messagebox, simpledialog, ttk
    root = tk.Tk()
    BridgeApp(root)
    root.mainloop()
