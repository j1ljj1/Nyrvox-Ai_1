# -*- coding: utf-8 -*-
import os, json, threading
from datetime import datetime
from kivy.app import App
from kivy.clock import Clock
from kivy.core.clipboard import Clipboard
from kivy.metrics import dp
from kivy.utils import get_color_from_hex
from kivy.graphics import Color, RoundedRectangle
from kivy.uix.boxlayout import BoxLayout
from kivy.uix.button import Button
from kivy.uix.label import Label
from kivy.uix.textinput import TextInput
from kivy.uix.scrollview import ScrollView
from kivy.uix.popup import Popup

try:
    from google import genai
    from google.genai import types
except ImportError:
    genai = None
    types = None

BG = get_color_from_hex("#0D0B14")
PANEL = get_color_from_hex("#191522")
PURPLE = get_color_from_hex("#9B7BFF")
TEXT = get_color_from_hex("#F6F2FF")
MUTED = get_color_from_hex("#B6ADC9")
USER_BG = get_color_from_hex("#302542")
MODEL = "gemini-2.5-flash"
SYSTEM_PROMPT = (
    "You are SHADOW AI, a helpful and accurate AI and coding assistant. "
    "Explain code clearly, put code in fenced code blocks, and never invent facts."
)

def load_json(path, fallback):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError, TypeError):
        return fallback

def save_json(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    temp_path = path + ".tmp"
    with open(temp_path, "w", encoding="utf-8") as f:
        json.dump(value, f, ensure_ascii=False, indent=2)
    os.replace(temp_path, path)

class ShadowAI(App):
    title = "SHADOW AI"

    def build(self):
        self.config_path = os.path.join(self.user_data_dir, "config.json")
        self.history_path = os.path.join(self.user_data_dir, "history.json")
        self.settings = load_json(self.config_path, {})
        self.history = load_json(self.history_path, [])
        self.client = None
        self.busy = False

        root = BoxLayout(orientation="vertical", padding=dp(10), spacing=dp(8))
        with root.canvas.before:
            Color(*BG)
            self.bg_rect = RoundedRectangle(pos=root.pos, size=root.size)
        root.bind(pos=self.update_bg, size=self.update_bg)

        header = BoxLayout(size_hint_y=None, height=dp(56), spacing=dp(8))
        brand = Label(text="[b]SHADOW AI[/b]\\n[size=12]Your AI coding assistant[/size]",
                      markup=True, color=TEXT, halign="left", valign="middle")
        brand.bind(size=lambda widget, size: setattr(widget, "text_size", size))
        header.add_widget(brand)
        settings_button = Button(text="Settings", size_hint_x=None, width=dp(94),
                                 background_normal="", background_color=PURPLE, color=BG)
        settings_button.bind(on_release=lambda *_: self.show_settings())
        header.add_widget(settings_button)
        root.add_widget(header)

        toolbar = BoxLayout(size_hint_y=None, height=dp(42), spacing=dp(6))
        new_button = Button(text="New chat", background_normal="", background_color=PANEL, color=TEXT)
        new_button.bind(on_release=lambda *_: self.new_chat())
        copy_button = Button(text="Copy last reply", background_normal="", background_color=PANEL, color=TEXT)
        copy_button.bind(on_release=lambda *_: self.copy_last())
        toolbar.add_widget(new_button)
        toolbar.add_widget(copy_button)
        root.add_widget(toolbar)

        self.scroll = ScrollView(do_scroll_x=False)
        self.chat = BoxLayout(orientation="vertical", size_hint_y=None, spacing=dp(8), padding=dp(5))
        self.chat.bind(minimum_height=self.chat.setter("height"))
        self.scroll.add_widget(self.chat)
        root.add_widget(self.scroll, 1)

        self.status = Label(text="Ready. Add your Gemini API key in Settings.",
                            color=MUTED, size_hint_y=None, height=dp(28), font_size="12sp")
        root.add_widget(self.status)

        composer = BoxLayout(size_hint_y=None, height=dp(96), spacing=dp(6))
        self.message_input = TextInput(
            hint_text="Type your message...", multiline=True,
            background_color=PANEL, foreground_color=TEXT,
            hint_text_color=MUTED, cursor_color=PURPLE, padding=dp(10)
        )
        composer.add_widget(self.message_input)
        self.send_button = Button(text="Send", size_hint_x=None, width=dp(78),
                                  background_normal="", background_color=PURPLE, color=BG)
        self.send_button.bind(on_release=lambda *_: self.send_message())
        composer.add_widget(self.send_button)
        root.add_widget(composer)

        self.render_history()
        if not self.settings.get("api_key"):
            Clock.schedule_once(lambda *_: self.show_settings(), 0.6)
        return root

    def update_bg(self, widget, *_):
        self.bg_rect.pos = widget.pos
        self.bg_rect.size = widget.size

    def show_settings(self):
        panel = BoxLayout(orientation="vertical", padding=dp(12), spacing=dp(9))
        panel.add_widget(Label(text="Gemini API key (stored locally on this device)",
                               color=TEXT, size_hint_y=None, height=dp(42)))
        key_input = TextInput(text=self.settings.get("api_key", ""), password=True,
                              multiline=False, hint_text="Paste API key here",
                              size_hint_y=None, height=dp(46))
        panel.add_widget(key_input)
        panel.add_widget(Label(text="Model: " + MODEL, color=MUTED,
                               size_hint_y=None, height=dp(28)))
        buttons = BoxLayout(size_hint_y=None, height=dp(44), spacing=dp(8))
        save_button = Button(text="Save", background_normal="", background_color=PURPLE, color=BG)
        close_button = Button(text="Close", background_normal="", background_color=PANEL, color=TEXT)
        buttons.add_widget(save_button)
        buttons.add_widget(close_button)
        panel.add_widget(buttons)
        popup = Popup(title="SHADOW AI Settings", content=panel, size_hint=(0.92, None),
                      height=dp(255), separator_color=PURPLE)

        def save_key(*_):
            key = key_input.text.strip()
            if not key:
                self.status.text = "Please enter a valid API key."
                return
            self.settings["api_key"] = key
            save_json(self.config_path, self.settings)
            self.client = None
            self.status.text = "API key saved locally."
            popup.dismiss()

        save_button.bind(on_release=save_key)
        close_button.bind(on_release=lambda *_: popup.dismiss())
        popup.open()

    def render_history(self):
        self.chat.clear_widgets()
        items = self.history[-100:] or [{
            "role": "assistant",
            "content": "Welcome to SHADOW AI. Ask me about coding or any topic you want to understand."
        }]
        for item in items:
            self.add_bubble(item.get("role", "assistant"), item.get("content", ""))
        Clock.schedule_once(lambda *_: setattr(self.scroll, "scroll_y", 0), 0.12)

    def add_bubble(self, role, content):
        is_user = role == "user"
        bubble = BoxLayout(orientation="vertical", size_hint_y=None, padding=dp(11), spacing=dp(5))
        with bubble.canvas.before:
            Color(*(USER_BG if is_user else PANEL))
            shape = RoundedRectangle(pos=bubble.pos, size=bubble.size, radius=[dp(12)])
        bubble.bind(pos=lambda widget, pos: setattr(shape, "pos", pos),
                    size=lambda widget, size: setattr(shape, "size", size))
        heading = Label(text="[b]You[/b]" if is_user else "[b]SHADOW AI[/b]",
                        markup=True, color=TEXT if is_user else PURPLE,
                        size_hint_y=None, height=dp(22), halign="left", valign="middle")
        heading.bind(size=lambda widget, size: setattr(widget, "text_size", size))
        body = Label(text=str(content), color=TEXT, size_hint_y=None, halign="left", valign="top")
        body.bind(width=lambda widget, width: setattr(widget, "text_size", (max(width-dp(8), dp(50)), None)))
        body.bind(texture_size=lambda widget, size: setattr(widget, "height", size[1] + dp(8)))
        bubble.add_widget(heading)
        bubble.add_widget(body)
        bubble.height = dp(38) + body.height
        self.chat.add_widget(bubble)
        Clock.schedule_once(lambda *_: setattr(self.scroll, "scroll_y", 0), 0.12)

    def persist_history(self):
        save_json(self.history_path, self.history)

    def new_chat(self):
        self.history = []
        self.persist_history()
        self.render_history()
        self.status.text = "Started a new chat."

    def copy_last(self):
        for item in reversed(self.history):
            if item.get("role") == "assistant":
                Clipboard.copy(item.get("content", ""))
                self.status.text = "Last reply copied."
                return
        self.status.text = "There is no reply to copy yet."

    def send_message(self):
        prompt = self.message_input.text.strip()
        if not prompt or self.busy:
            return
        if not self.settings.get("api_key"):
            self.show_settings()
            self.status.text = "Add your API key first."
            return
        if genai is None:
            self.status.text = "google-genai is unavailable. Check the build instructions."
            return

        self.message_input.text = ""
        self.history.append({"role": "user", "content": prompt, "time": datetime.now().isoformat()})
        self.persist_history()
        self.add_bubble("user", prompt)
        self.busy = True
        self.send_button.disabled = True
        self.status.text = "SHADOW AI is thinking..."
        threading.Thread(target=self.request_worker, daemon=True).start()

    def request_worker(self):
        try:
            if self.client is None:
                self.client = genai.Client(api_key=self.settings["api_key"])
            contents = []
            for item in self.history[-20:]:
                role = item.get("role")
                if role in ("user", "assistant"):
                    contents.append({
                        "role": "user" if role == "user" else "model",
                        "parts": [{"text": item.get("content", "")}]
                    })
            response = self.client.models.generate_content(
                model=MODEL,
                contents=contents,
                config=types.GenerateContentConfig(
                    system_instruction=SYSTEM_PROMPT,
                    temperature=0.7,
                    max_output_tokens=2048
                )
            )
            answer = (response.text or "").strip() or "No text response received. Please try again."
            Clock.schedule_once(lambda *_: self.finish_request(answer, None), 0)
        except Exception as exc:
            error_name = type(exc).__name__
            message = "Connection failed. Check your internet connection and API key."
            if "429" in str(exc) or "ResourceExhausted" in error_name:
                message = "Usage limit reached temporarily. Please try again later."
            elif "401" in str(exc) or "403" in str(exc) or "PermissionDenied" in error_name:
                message = "The API key is invalid or does not have access."
            Clock.schedule_once(lambda *_: self.finish_request(None, message), 0)

    def finish_request(self, answer, error):
        self.busy = False
        self.send_button.disabled = False
        if error:
            self.status.text = error
            self.add_bubble("assistant", error)
            return
        self.history.append({"role": "assistant", "content": answer, "time": datetime.now().isoformat()})
        self.persist_history()
        self.add_bubble("assistant", answer)
        self.status.text = "Reply complete. Saved locally."

if __name__ == "__main__":
    ShadowAI().run()
