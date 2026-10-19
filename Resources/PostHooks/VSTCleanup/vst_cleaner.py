#!/usr/bin/env python3
"""
Move duplicate plugin formats to /tmp (including nested subdirectories).
Defaults to /tmp/removed_plugins and falls back to /tmp/removed_plugins_<user>.
VST3 bundles shadowed by AU are preserved under /usr/local/vst3-cleaned so
DAWs without AU support can add that folder explicitly.

Prefers AU; falls back to VST3 only when Ableton's plugin index doesn't
already show the AU twin. Truth source is Live's own database — a VST3
is moved aside only when Live actually has both AU and VST3 entries
for the plugin. AU is never moved (Logic depends on it).

Removes (match by bundle base name, case-insensitive):
  - VST3 bundles whose AU twin Ableton already indexes (per Live's DB)
  - AU twins of PREFER_VST3 exception plugins (VST3 kept instead; only
    when the VST3 exists on disk — exact stem match, so sibling
    "<name> MIDI FX" components are never touched)
  - VST2/AAX/CLAP bundles with a matching AU or VST3 name
  - Old Waves WaveShell versions (e.g. 16.6 when 16.7 exists)
  - Non-production Waves plugins (surround, broadcast, live sound, etc.)
  - Redundant Waves mono and surround sub-components
  - Max for Live .adv presets shadowed by a same-named .amxd device,
    inside Live's User Library (auto-detected from Live's database)

Opt-in (off by default):
  - Plugins with broken/invalid code signatures (enable with 'checkbroken').
    Slow — runs `codesign --verify` on every installed plugin.

Keeps:
  - AU bundles (.component) — never removed, except AU twins of
    PREFER_VST3 exception plugins
  - VST3 bundles whose AU twin is NOT in Ableton's index (so Live and
    Logic both still load the plugin)
  - VST3 bundles of PREFER_VST3 exception plugins, and their MIDI FX
    AU variants (e.g. "Stellarizer MIDI FX.component")
  - Any other format that doesn't have an AU or VST3 duplicate

Options:
  skipwavesmono  — Skip stripping Waves mono sub-components
  skipm4l        — Skip Max for Live .adv-shadowed-by-.amxd cleanup
  checkbroken    — Enable codesign verification (slow, opt-in)

Reports (read-only, no plugins moved):
  usage          — Print markdown-table of most-used plugins / .amxd
                   from Ableton Live's database (use_count > 10)
"""

import base64
from datetime import datetime
import getpass
import hashlib
import hmac
import json
import os
import platform
import re
import secrets
import shutil
import subprocess
import sys
import uuid
from pathlib import Path
from specifics.fabfilter import find_obsolete as find_obsolete_fabfilter
from specifics.revoice import find_obsolete as find_obsolete_revoice
from specifics.broken import find_broken as find_broken_codesign
from specifics.m4l import find_redundant_adv as find_redundant_m4l_adv
from specifics.ableton_dedup import (
    find_vst3_shadowed_by_au,
    diagnostics as ableton_diagnostics,
)
from specifics.usage import print_usage_report

CACHE_FILE = Path(__file__).resolve().parent / ".cache"
CACHE_VERSION = 1
PBKDF2_ITERATIONS = 200_000
_CACHED_PASSWORD: str | None = None
_CACHE_LOOKED_UP = False
_KEY_MATERIAL: bytes | None = None


def _int_env(name: str, default: int) -> int:
    """Parse integer from environment variable."""
    value = os.environ.get(name)
    if not value:
        return default
    try:
        return int(value)
    except ValueError:
        return default


def _get_key_material() -> bytes:
    """Derive stable machine-specific key material."""
    global _KEY_MATERIAL
    if _KEY_MATERIAL is None:
        parts = [
            "vst_cleaner",
            getpass.getuser(),
            str(Path.home()),
            platform.node(),
            hex(uuid.getnode()),
            sys.platform,
        ]
        _KEY_MATERIAL = "|".join(parts).encode("utf-8")
    return _KEY_MATERIAL


def _derive_master_key(salt: bytes) -> bytes:
    """Derive an encryption key from machine-specific material and salt."""
    return hashlib.pbkdf2_hmac("sha256", _get_key_material(), salt, PBKDF2_ITERATIONS, dklen=32)


def _hkdf_expand(key: bytes, info: bytes, length: int) -> bytes:
    """Minimal HKDF-Expand for fixed-length keys."""
    output = b""
    counter = 1
    prev = b""
    while len(output) < length:
        prev = hmac.new(key, prev + info + bytes([counter]), hashlib.sha256).digest()
        output += prev
        counter += 1
    return output[:length]


def _split_keys(master_key: bytes) -> tuple[bytes, bytes]:
    """Split master key into encryption and MAC keys."""
    enc_key = _hkdf_expand(master_key, b"enc", 32)
    mac_key = _hkdf_expand(master_key, b"mac", 32)
    return enc_key, mac_key


def _xor_stream(data: bytes, key: bytes, nonce: bytes) -> bytes:
    """XOR data with a keyed HMAC stream."""
    output = bytearray(len(data))
    counter = 0
    offset = 0
    while offset < len(data):
        counter_bytes = counter.to_bytes(8, "big")
        block = hmac.new(key, nonce + counter_bytes, hashlib.sha256).digest()
        block_len = min(len(block), len(data) - offset)
        for idx in range(block_len):
            output[offset + idx] = data[offset + idx] ^ block[idx]
        offset += block_len
        counter += 1
    return bytes(output)


def encrypt_password(password: str) -> dict[str, str]:
    """Encrypt password into a JSON-serializable payload."""
    salt = secrets.token_bytes(16)
    nonce = secrets.token_bytes(16)
    master_key = _derive_master_key(salt)
    enc_key, mac_key = _split_keys(master_key)
    ciphertext = _xor_stream(password.encode("utf-8"), enc_key, nonce)
    mac = hmac.new(mac_key, nonce + ciphertext, hashlib.sha256).digest()
    return {
        "v": str(CACHE_VERSION),
        "salt": base64.urlsafe_b64encode(salt).decode("ascii"),
        "nonce": base64.urlsafe_b64encode(nonce).decode("ascii"),
        "ciphertext": base64.urlsafe_b64encode(ciphertext).decode("ascii"),
        "mac": base64.urlsafe_b64encode(mac).decode("ascii"),
    }


def decrypt_password(payload: dict[str, str]) -> str | None:
    """Decrypt password payload or return None on failure."""
    try:
        if str(payload.get("v")) != str(CACHE_VERSION):
            return None
        salt = base64.urlsafe_b64decode(payload["salt"])
        nonce = base64.urlsafe_b64decode(payload["nonce"])
        ciphertext = base64.urlsafe_b64decode(payload["ciphertext"])
        mac = base64.urlsafe_b64decode(payload["mac"])
    except (KeyError, ValueError, base64.binascii.Error):
        return None

    master_key = _derive_master_key(salt)
    enc_key, mac_key = _split_keys(master_key)
    expected_mac = hmac.new(mac_key, nonce + ciphertext, hashlib.sha256).digest()
    if not hmac.compare_digest(expected_mac, mac):
        return None
    plaintext = _xor_stream(ciphertext, enc_key, nonce)
    try:
        return plaintext.decode("utf-8")
    except UnicodeDecodeError:
        return None


def get_cached_password() -> str | None:
    """Retrieve password from encrypted cache file."""
    if not CACHE_FILE.exists():
        return None
    try:
        payload = json.loads(CACHE_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    password = decrypt_password(payload)
    if not password:
        try:
            CACHE_FILE.unlink()
        except OSError:
            pass
    return password


def save_password_to_cache(password: str) -> bool:
    """Save password to encrypted cache file."""
    payload = encrypt_password(password)
    try:
        CACHE_FILE.write_text(json.dumps(payload), encoding="utf-8")
        os.chmod(CACHE_FILE, 0o600)
        return True
    except OSError:
        return False


def run_with_sudo(
    cmd: list[str], password: str, timeout: int | None = None
) -> subprocess.CompletedProcess:
    """Run a command with sudo, passing password via stdin."""
    proc = subprocess.Popen(
        ["sudo", "-S"] + cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        stdout, stderr = proc.communicate(
            input=(password + "\n").encode(), timeout=timeout
        )
        return subprocess.CompletedProcess(cmd, proc.returncode, stdout, stderr)
    except subprocess.TimeoutExpired:
        proc.kill()
        stdout, stderr = proc.communicate()
        timeout_note = f"Command timed out after {timeout} seconds.".encode("utf-8")
        if stderr:
            stderr = stderr + b"\n" + timeout_note
        else:
            stderr = timeout_note
        return subprocess.CompletedProcess(cmd, 124, stdout, stderr)


def verify_sudo_password(password: str) -> bool:
    """Verify the password works with sudo."""
    # Kill any cached sudo credentials first to ensure we test the actual password
    subprocess.run(["sudo", "-k"], capture_output=True)
    result = run_with_sudo(["-v"], password)
    return result.returncode == 0


def cache_password(password: str) -> None:
    """Cache the password in memory for this run."""
    global _CACHED_PASSWORD, _CACHE_LOOKED_UP
    _CACHED_PASSWORD = password
    _CACHE_LOOKED_UP = True


def clear_cached_password(remove_file: bool = False) -> None:
    """Clear cached password, optionally removing the cache file."""
    global _CACHED_PASSWORD, _CACHE_LOOKED_UP
    _CACHED_PASSWORD = None
    _CACHE_LOOKED_UP = True
    if remove_file:
        try:
            CACHE_FILE.unlink()
        except OSError:
            pass


def prompt_for_password() -> str:
    """Prompt for sudo password and save it to the encrypted cache."""
    print("Root password required (will be stored encrypted in .cache)")
    for _ in range(3):
        password = getpass.getpass("Password: ")
        if verify_sudo_password(password):
            if save_password_to_cache(password):
                print("Password cached for future use.\n")
            cache_password(password)
            return password
        print("Incorrect password, try again.")

    raise SystemExit("Failed to authenticate after 3 attempts.")


def can_prompt_for_password() -> bool:
    """Check whether we can prompt for a password."""
    return sys.stdin.isatty() and sys.stderr.isatty()


def get_sudo_password() -> str | None:
    """Get sudo password from cache or prompt if missing."""
    global _CACHED_PASSWORD, _CACHE_LOOKED_UP
    if _CACHED_PASSWORD:
        return _CACHED_PASSWORD
    if not _CACHE_LOOKED_UP:
        _CACHED_PASSWORD = get_cached_password()
        _CACHE_LOOKED_UP = True
    if _CACHED_PASSWORD:
        return _CACHED_PASSWORD
    if not can_prompt_for_password():
        return None
    return prompt_for_password()


def is_auth_failure(result: subprocess.CompletedProcess) -> bool:
    """Check whether sudo failed due to authentication."""
    if result.returncode == 0:
        return False
    output = b""
    if result.stderr:
        output += result.stderr
    if result.stdout:
        output += result.stdout
    message = output.decode(errors="ignore").lower()
    return any(
        token in message
        for token in (
            "sorry, try again",
            "incorrect password",
            "password is required",
            "no password was provided",
            "authentication failure",
        )
    )


def run_with_sudo_retry(
    cmd: list[str], timeout: int | None = None
) -> tuple[bool, str | None]:
    """Run sudo command, prompting again if cached password is invalid."""
    password = get_sudo_password()
    if not password:
        return False, "sudo password unavailable"
    result = run_with_sudo(cmd, password, timeout=timeout)
    if result.returncode == 0:
        return True, None
    if is_auth_failure(result):
        clear_cached_password(remove_file=True)
        password = get_sudo_password()
        if not password:
            return False, "sudo password unavailable"
        result = run_with_sudo(cmd, password, timeout=timeout)
    if result.returncode == 0:
        return True, None
    output = b""
    if result.stderr:
        output += result.stderr
    if result.stdout:
        output += result.stdout
    message = output.decode(errors="ignore").strip()
    return False, message or "sudo failed"

# System-level plugin directories
SYSTEM_VST_PATH = Path("/Library/Audio/Plug-Ins/VST")
SYSTEM_COMPONENTS_PATH = Path("/Library/Audio/Plug-Ins/Components")
SYSTEM_AAX_PATH = Path("/Library/Application Support/Avid/Audio/Plug-Ins")
SYSTEM_CLAP_PATH = Path("/Library/Audio/Plug-Ins/CLAP")

# User-level plugin directories
USER_VST_PATH = Path.home() / "Library/Audio/Plug-Ins/VST"
USER_COMPONENTS_PATH = Path.home() / "Library/Audio/Plug-Ins/Components"
USER_AAX_PATH = Path.home() / "Library/Application Support/Avid/Audio/Plug-Ins"
USER_CLAP_PATH = Path.home() / "Library/Audio/Plug-Ins/CLAP"

# VST3 directories (for duplicate matching)
SYSTEM_VST3_PATH = Path("/Library/Audio/Plug-Ins/VST3")
USER_VST3_PATH = Path.home() / "Library/Audio/Plug-Ins/VST3"

DEFAULT_TMP_PATH = Path.home() / "Desktop/back13may"
VST3_CLEANED_PATH = Path("/usr/local/vst3-cleaned")

# ---------------------------------------------------------------------------
# Protected plugins — NEVER remove these even if a VST3 duplicate exists.
# Matched case-insensitively against the plugin base name (stem).
# ---------------------------------------------------------------------------
NEVER_REMOVE: set[str] = {
    "vsx",
    "melodyne",
}

# ---------------------------------------------------------------------------
# Format-preference exceptions — INVERT the default AU-preferred policy for
# these plugins: keep the VST3, move the AU twin aside instead.
# Matched case-insensitively against the exact bundle base name (stem), so
# sibling bundles like "<name> MIDI FX.component" never match — MIDI FX
# variants (AU-only, Logic depends on them) are always kept.
# The AU is moved only when the VST3 twin actually exists on disk.
# ---------------------------------------------------------------------------
PREFER_VST3: set[str] = {
    "stellarizer",
    "glitchwork",
    "textureloom",
}

# ---------------------------------------------------------------------------
# Waves-specific duplicate handling
# ---------------------------------------------------------------------------
# WaveShell AU and VST3 use different naming conventions:
#   AU:   "WaveShell1-AU 16.7.component"
#   VST3: "WaveShell1-VST3 16.7.vst3"
# The standard base-name matching can't catch these, so we hardcode them.
#
# NOTE: Waves mono/stereo sub-plugin variants (m), (s), (m->s) are all
# registered inside the same WaveShell container and CANNOT be removed by
# deleting files. Use your DAW's plugin manager to hide unwanted variants.
# The full list of 229 mono-redundant Waves plugins is documented below.

# Old WaveShell versions superseded by newer installs — always safe to remove.
WAVES_OBSOLETE: list[tuple[Path, str]] = [
    (Path("/Library/Audio/Plug-Ins/VST3"), "WaveShell1-VST3 16.6.vst3"),
    (Path("/Library/Audio/Plug-Ins/Components"), "WaveShell1-AU 16.6.component"),
]

# Waves plugin directories (plugin bundles with ProcessXML sub-component defs)
WAVES_PLUGINS_SYSTEM = Path("/Applications/Waves/Plug-Ins V16")
WAVES_PLUGINS_USER = Path.home() / "Library/Preferences/Waves Preferences/Waves Plugins V16"

# WaveShell scan cache — must be deleted after modifying ProcessXML so the
# WaveShell rebuilds its sub-plugin list on next DAW launch.
WAVES_SCAN_CACHE_DIR = Path.home() / "Library/Caches/Waves"

# Waves plugins not relevant for music production — surround, broadcast,
# live sound, networking, test utilities.  Moved to tmp on each run.
# See specifics/waves.txt for rationale.
WAVES_NON_PRODUCTION: list[str] = [
    # Surround / Immersive / 360 (post-production, film, Atmos)
    "B360.bundle",
    "C360.bundle",
    "Dorrough Surround 5.0.bundle",
    "Dorrough Surround 5.1.bundle",
    "DTS Neural DownMix.bundle",
    "DTS Neural Mono2Stereo.bundle",
    "DTS Neural UpMix.bundle",
    "IR-360.bundle",
    "Immersive Wrapper.bundle",
    "L360.bundle",
    "LFE360.bundle",
    "MV360.bundle",
    "R360.bundle",
    "S360.bundle",
    "Spherix Immersive Compressor.bundle",
    "Spherix Immersive Limiter.bundle",
    "UM.bundle",
    # Live sound / Installation
    "Dugan Speech.bundle",
    "EMO-IEM.bundle",
    "Feedback Hunter.bundle",
    "TRACT.bundle",
    "X-FDBK.bundle",
    "Sub Align.bundle",
    # Broadcast-specific
    "WLM.bundle",
    # Networking
    "Waves Stream.bundle",
    # Test utility
    "SignalGenerator.bundle",
]

# Waves plugins that have BOTH mono (m) and stereo (s) variants inside the
# WaveShell.  The mono versions are redundant when stereo exists.
# Stripped from ProcessXML files so the WaveShell no longer registers them.
WAVES_MONO_REDUNDANT: list[str] = [
    "API-2500",
    "API-550A",
    "API-550B",
    "API-560",
    "Abbey Road Chambers",
    "Abbey Road EMI TG12345 Ch",
    "Abbey Road J37 Tape",
    "Abbey Road Plates",
    "Abbey Road REDD.17",
    "Abbey Road REDD.37.51",
    "Abbey Road RS124",
    "Abbey Road RS56 Passive EQ",
    "Abbey Road Reel ADT",
    "Abbey Road Reel ADT Live",
    "Abbey Road Saturator",
    "Abbey Road TG Mastering",
    "Abbey Road TG Mastering Live",
    "Abbey Road TG Meter Bridge",
    "Abbey Road The King's Microphones",
    "Abbey Road Vinyl",
    "Abbey Road Vinyl Light",
    "Aphex Vintage Exciter",
    "AudioTrack",
    "Bass Rider",
    "Bass Rider Live",
    "Berzerk Distortion",
    "Butch Vig Vocals",
    "C1 comp",
    "C1 comp-gate",
    "C1 comp-sc",
    "C1 gate",
    "C4",
    "C6",
    "C6-SideChain",
    "CLA MixDown",
    "CLA MixHub",
    "CLA MixHub Lite",
    "CLA-2A",
    "CLA-3A",
    "CLA-76",
    "Clarity Vx",
    "Clarity Vx - DeReverb",
    "Clarity Vx - DeReverb Pro",
    "Clarity Vx Pro",
    "Curves AQ",
    "Curves AQ Live",
    "Curves Equator",
    "Curves Equator Live",
    "Curves Resolve",
    "Curves Resolve Live",
    "DPR-402",
    "DeEsser",
    "Dorrough",
    "Doubler2",
    "Doubler4",
    "EKramer BA",
    "EKramer DR",
    "EMO-D5",
    "EMO-F2",
    "EMO-Generator",
    "EMO-Q4",
    "F6",
    "F6-RTA",
    "GEQ Classic",
    "GEQ Modern",
    "GTR Amp",
    "GTR Stomp 2",
    "GTR Stomp 4",
    "GTR Stomp 6",
    "GW MixCentric",
    "GW PianoCentric",
    "GW ToneCentric",
    "GW VoiceCentric",
    "H-Comp",
    "H-Delay",
    "H-EQ",
    "H-EQ-Light",
    "H-Reverb",
    "H-Reverb long",
    "IDX Intelligent Dynamics",
    "IDX LIVE Intelligent Dynamics",
    "IMPusher",
    "IR-L",
    "IR1",
    "IRLive",
    "InPhase",
    "InPhase LT",
    "InPhase LT Live",
    "InPhase Live",
    "InTrigger",
    "InTrigger Live",
    "JJP-Bass",
    "JJP-Drums",
    "Kaleidoscopes",
    "Key Detector",
    "Kramer HLS",
    "Kramer PIE",
    "Kramer Tape",
    "L1 limiter",
    "L2",
    "L2-SC",
    "L3 MultiMaximizer",
    "L3 UltraMaximizer",
    "L3-LL Multi",
    "L3-LL Ultra",
    "L316",
    "L4 Ultramaximizer",
    "LinEQ Broadband",
    "LinEQ Lowband",
    "LinMB",
    "LoAir",
    "Lofi Space",
    "MDMX Fuzz",
    "MDMX OverDrive",
    "MDMX Screamer",
    "MV2",
    "Magma BB Tubes",
    "Magma Channel Strip",
    "Magma Lil Tube",
    "Magma Springs",
    "MannyM Distortion",
    "MannyM EQ",
    "MannyM Reverb",
    "MannyM Tone Shaper",
    "MannyM TripleD",
    "Maserati B72",
    "Maserati DRM",
    "Maserati GRP",
    "MaxxBass",
    "MaxxVolume",
    "MetaFilter",
    "MetaFlanger",
    "MondoMod",
    "Morphoder",
    "MultiMod Rack",
    "NLS Buss",
    "NLS Channel",
    "NS1",
    "OneKnob Brighter",
    "OneKnob Driver",
    "OneKnob Filter",
    "OneKnob Louder",
    "OneKnob Phatter",
    "OneKnob Pressure",
    "OneKnob Pumper",
    "OneKnob Wetter",
    "PAZ- Frequency",
    "PAZ- Meters",
    "PRS Archon",
    "PRS Dallas",
    "PRS V9",
    "PSE",
    "PlaylistRider",
    "PuigTec EQP1A",
    "PuigTec MEQ5",
    "Q-Clone",
    "Q1",
    "Q10",
    "Q2",
    "Q3",
    "Q4",
    "Q6",
    "Q8",
    "RBass",
    "RChannel",
    "RCompressor",
    "RDeEsser",
    "REQ 2",
    "REQ 4",
    "REQ 6",
    "RVox",
    "Renaissance Axx",
    "Retro Fi",
    "SSL EV2 Channel",
    "SSLChannel",
    "SSLComp",
    "SSLEQ",
    "SSLGChannel",
    "Saphira",
    "Scheps 73",
    "Scheps Omni Channel 2",
    "Scheps Parallel Particles",
    "Sibilance",
    "Sibilance-Live",
    "Silk Vocal",
    "Silk Vocal Live",
    "Smack Attack",
    "SoundShifter Pitch",
    "StudioVerse Audio Effects",
    "Sub Align",
    "Submarine",
    "SuperTap 2-Taps",
    "SuperTap 6-Taps",
    "TRACT",
    "TRACT LinPhase",
    "Torque",
    "Torque-Live",
    "TransX Multi",
    "TransX Wide",
    "TrueVerb",
    "UltraPitch 3 Voices",
    "UltraPitch 6 Voices",
    "UltraPitch Shift",
    "VComp",
    "VEQ3",
    "VEQ4",
    "VU Meter",
    "Vitamin",
    "Vocal Bender",
    "Vocal Rider",
    "Vocal Rider Live",
    "Voltage Amps Bass",
    "Voltage Amps Guitar",
    "W43",
    "WLM Meter",
    "WLM Plus",
    "WNS",
    "Waves Stream Receive",
    "Waves Stream Send",
    "Waves Tune",
    "Waves Tune LT",
    "Waves Tune Real-Time",
    "X-Click",
    "X-Crackle",
    "X-FDBK",
    "X-Hum",
    "X-Noise",
    "Z-Noise",
    "dbx-160",
]


def list_bundles(folder: Path, suffix: str) -> list[Path]:
    """List bundle paths in folder matching suffix (case-insensitive, recursive)."""
    if not folder.exists() or not folder.is_dir():
        return []
    suffix = suffix.lower()
    matches: list[Path] = []
    for root, dirs, files in os.walk(folder):
        root_path = Path(root)
        keep_dirs = []
        for dirname in dirs:
            path = root_path / dirname
            if path.suffix.lower() == suffix:
                matches.append(path)
            else:
                keep_dirs.append(dirname)
        dirs[:] = keep_dirs
        for filename in files:
            if filename.lower().endswith(suffix):
                matches.append(root_path / filename)
    return matches


def plugin_base_name(path: Path) -> str:
    """Normalize plugin name for de-duping."""
    return path.stem.lower()


def get_vst3_names(folder: Path) -> set[str]:
    """Collect VST3 base names from folder."""
    return {plugin_base_name(item) for item in list_bundles(folder, ".vst3")}


def get_au_names(folder: Path) -> set[str]:
    """Collect AU (.component) base names from folder."""
    return {plugin_base_name(item) for item in list_bundles(folder, ".component")}


def is_writable_dir(path: Path) -> bool:
    """Check whether directory is writable and searchable."""
    return os.access(path, os.W_OK | os.X_OK)


def can_create_dir(path: Path) -> bool:
    """Check whether directory exists and is writable, or can be created."""
    if path.exists():
        return is_writable_dir(path)
    parent = path.parent
    return parent.exists() and is_writable_dir(parent)


def resolve_tmp_base(base: Path) -> Path:
    """Pick a writable base path for removed plugins."""
    user = getpass.getuser()
    candidates = [
        base,
        Path(f"{base}_{user}"),
        Path(f"{base}_{user}_{os.getpid()}"),
    ]
    for candidate in candidates:
        if can_create_dir(candidate):
            return candidate
    return base


def get_size(path: Path) -> int:
    """Get total size of a file or directory in bytes."""
    if path.is_file() or path.is_symlink():
        return path.stat().st_size
    total = 0
    for root, _, files in os.walk(path):
        for f in files:
            try:
                total += (Path(root) / f).stat().st_size
            except OSError:
                pass
    return total


def human_size(num_bytes: int) -> str:
    """Convert bytes to human readable format."""
    for unit in ["B", "KB", "MB", "GB"]:
        if num_bytes < 1024:
            return f"{num_bytes:.1f} {unit}"
        num_bytes /= 1024
    return f"{num_bytes:.1f} TB"


def unique_dest_path(dest_dir: Path, src_name: str) -> Path:
    """Create a unique destination path to avoid collisions."""
    dest = dest_dir / src_name
    if not dest.exists():
        return dest
    stem = Path(src_name).stem
    suffix = Path(src_name).suffix
    for idx in range(1, 1000):
        candidate = dest_dir / f"{stem}__{idx}{suffix}"
        if not candidate.exists():
            return candidate
    return dest_dir / f"{stem}__{os.getpid()}{suffix}"


def move_path(path: Path, dest_dir: Path) -> tuple[bool, str | None]:
    """Move a file or directory to dest_dir, using sudo if needed."""
    dest = unique_dest_path(dest_dir, path.name)
    try:
        shutil.move(str(path), str(dest))
        return True, None
    except PermissionError as exc:
        ok, message = run_with_sudo_retry(["mv", str(path), str(dest)])
        return ok, message or str(exc)
    except OSError as exc:
        return False, str(exc)


def ensure_dir(dest_dir: Path) -> bool:
    """Create directory, using sudo if needed."""
    if dest_dir.exists():
        return True
    try:
        dest_dir.mkdir(parents=True, exist_ok=True)
        return True
    except PermissionError:
        ok, _ = run_with_sudo_retry(["mkdir", "-p", str(dest_dir)])
        return ok

def remove_hardcoded_files(
    removals: list[tuple[Path, str]],
    dest_dir: Path,
    failures: list[str] | None = None,
) -> tuple[list[str], int]:
    """Move hardcoded plugin files (by exact directory + filename)."""
    moved: list[str] = []
    bytes_moved = 0
    for folder, filename in removals:
        path = folder / filename
        if not path.exists():
            continue
        if not ensure_dir(dest_dir):
            continue
        size = get_size(path)
        ok, error = move_path(path, dest_dir)
        if ok:
            moved.append(filename)
            bytes_moved += size
        elif failures is not None:
            failures.append(f"{path} -> {error}")
    return moved, bytes_moved


def remove_duplicates_by_names(
    folder: Path,
    dest_dir: Path,
    suffix: str,
    preferred_names: set[str],
    failures: list[str] | None = None,
) -> tuple[list[str], int]:
    """Move bundles whose base name matches one in `preferred_names`.

    `preferred_names` is the set of stems (lowercased) that exist in a
    higher-priority format. Any bundle in `folder` whose stem appears in
    that set is treated as a duplicate and moved to `dest_dir`.
    """
    moved = []
    bytes_moved = 0

    if not preferred_names or not folder.exists() or not folder.is_dir():
        return moved, bytes_moved

    if not ensure_dir(dest_dir):
        return moved, bytes_moved

    for item in list_bundles(folder, suffix):
        name = plugin_base_name(item)
        if name not in preferred_names:
            continue
        if name in NEVER_REMOVE:
            continue
        size = get_size(item)
        ok, error = move_path(item, dest_dir)
        if ok:
            moved.append(item.name)
            bytes_moved += size
        elif failures is not None:
            failures.append(f"{item} -> {error}")

    return moved, bytes_moved


# ---------------------------------------------------------------------------
# Waves mono & surround sub-component stripping
# ---------------------------------------------------------------------------

# ProcessCodeDescription IDs to remove from template files.
# Mono: prevents the WaveShell from auto-generating mono variants.
# Surround: removes 5.0/5.1/7.x multichannel variants unused in stereo DAWs.
_STRIP_PCDESC_IDS = {
    # Mono
    "default_mono",
    "default_mono_to_stereo",
    "default_mono_side_chain",
    "default_mono_to_stereo_side_chain",
    # Surround / Immersive
    "default_5dot0",
    "default_5dot1",
    "default_5dot0_to_stereo",
    "default_5dot0_to_5dot1",
    "default_5dot1_to_stereo",
    "default_mono_to_5dot0",
    "default_mono_to_5dot1",
    "default_stereo_to_5dot0",
    "default_stereo_to_5dot1",
    "default_stereo_to_7dot1",
    "default_7dot0dot2",
    "default_7dot0dot4",
    "default_7dot1dot2",
    "default_7dot1dot4",
    "default_LRC_to_stereo",
}

# Ableton Live plugin database (shared across versions).
ABLETON_PLUGIN_DB = (
    Path.home()
    / "Library/Application Support/Ableton/Live Database/Live-plugins-1.db"
)


def _find_waves_plugin_dirs() -> list[Path]:
    """Return existing Waves plugin bundle directories."""
    dirs = []
    for d in [WAVES_PLUGINS_SYSTEM, WAVES_PLUGINS_USER]:
        if d.is_dir():
            dirs.append(d)
    return dirs


def _strip_mono_subcomponents(xml_text: str) -> tuple[str, int]:
    """Remove mono SubComponent blocks when a stereo block exists for same name.

    Handles both pure mono (default_mono) and mono-to-stereo
    (default_mono_to_stereo) variants.

    Returns (modified_xml, count_removed).
    """
    results = []
    for m in re.finditer(r'<SubComponent>.*?</SubComponent>', xml_text, re.DOTALL):
        block = m.group()
        name_m = re.search(r'Name="([^"]+)"', block)
        name = name_m.group(1) if name_m else None
        if not name:
            continue
        is_mono = any(mid in block for mid in _STRIP_PCDESC_IDS)
        is_stereo = 'default_stereo' in block
        results.append({
            'name': name,
            'mono': is_mono,
            'stereo': is_stereo,
            'span': m.span(),
        })

    stereo_names = {s['name'] for s in results if s['stereo']}
    to_remove = [s for s in results if s['mono'] and s['name'] in stereo_names]
    if not to_remove:
        return xml_text, 0

    to_remove.sort(key=lambda s: s['span'][0], reverse=True)
    result = xml_text
    for entry in to_remove:
        start, end = entry['span']
        while start > 0 and result[start - 1] in ' \t':
            start -= 1
        if end < len(result) and result[end] == '\n':
            end += 1
        result = result[:start] + result[end:]

    return result, len(to_remove)


def _strip_mono_descriptions(xml_text: str) -> tuple[str, int]:
    """Remove ProcessCodeDescription blocks that define mono configurations.

    These templates in SubComponentDefault.xml (1000.xml) cause the WaveShell
    to auto-generate mono variants for every plugin, even when no explicit
    mono SubComponent is defined.

    Returns (modified_xml, count_removed).
    """
    count = 0
    result = xml_text
    for mid in _STRIP_PCDESC_IDS:
        pattern = re.compile(
            rf'[ \t]*<ProcessCodeDescription\s+ID="{re.escape(mid)}">'
            r'.*?</ProcessCodeDescription>\s*',
            re.DOTALL,
        )
        result, n = pattern.subn('', result)
        count += n
    return result, count


def _strip_redundant_from_xml(xml_text: str) -> tuple[str, int]:
    """Remove mono and surround definitions from a ProcessXML file.

    Strips both explicit SubComponent blocks (from 1001.xml etc.) and
    ProcessCodeDescription templates (from 1000.xml / SubComponentDefault)
    for mono and surround configurations.

    Returns (modified_xml, total_count_removed).
    """
    result, sub_count = _strip_mono_subcomponents(xml_text)
    result, desc_count = _strip_mono_descriptions(result)
    return result, sub_count + desc_count


def strip_waves_mono() -> tuple[int, int]:
    """Strip mono sub-components from all Waves ProcessXML files.

    Returns (plugins_modified, items_removed).
    """
    plugins_modified = 0
    total_removed = 0

    for waves_dir in _find_waves_plugin_dirs():
        for bundle in sorted(waves_dir.iterdir()):
            if not bundle.name.endswith('.bundle'):
                continue
            pxml_dir = bundle / "Contents/Resources/ProcessXML"
            if not pxml_dir.is_dir():
                continue

            bundle_modified = False
            for xml_file in sorted(pxml_dir.glob("*.xml")):
                try:
                    original = xml_file.read_text(encoding='utf-8')
                except OSError:
                    continue

                modified, count = _strip_redundant_from_xml(original)
                if count == 0:
                    continue

                try:
                    xml_file.write_text(modified, encoding='utf-8')
                except PermissionError:
                    tmp = Path(f"/tmp/_waves_mono_{os.getpid()}.xml")
                    tmp.write_text(modified, encoding='utf-8')
                    run_with_sudo_retry(["cp", str(tmp), str(xml_file)])
                    tmp.unlink(missing_ok=True)

                total_removed += count
                bundle_modified = True

            if bundle_modified:
                plugins_modified += 1

    # Always clear the WaveShell scan cache so it rebuilds on next DAW launch
    _clear_waves_scan_cache()

    return plugins_modified, total_removed


def clear_ableton_waves_redundant() -> int:
    """Remove Waves mono and surround plugin entries from Ableton's plugin database.

    Returns the number of entries deleted.
    """
    if not ABLETON_PLUGIN_DB.exists():
        return 0
    try:
        import sqlite3 as _sqlite3

        conn = _sqlite3.connect(str(ABLETON_PLUGIN_DB))
        cur = conn.cursor()
        # Delete mono variants (name ends with "Mono" or contains "Mono/")
        # and surround variants (5.0, 5.1, 7.x, Quad, AmbiX, FuMa, LRC).
        cur.execute(
            "DELETE FROM plugins WHERE vendor = 'Waves' AND ("
            "  name LIKE '% Mono' OR name LIKE '% Mono/%'"
            "  OR name LIKE '% 5.0%' OR name LIKE '% 5.1%'"
            "  OR name LIKE '%/5.0%' OR name LIKE '%/5.1%'"
            "  OR name LIKE '% 7.0%' OR name LIKE '% 7.1%'"
            "  OR name LIKE '%/7.0%' OR name LIKE '%/7.1%'"
            "  OR name LIKE '% Quad%' OR name LIKE '%/Quad%'"
            "  OR name LIKE '% AmbiX%' OR name LIKE '% FuMa%'"
            "  OR name LIKE '%Ambisonics%'"
            ")"
        )
        deleted = cur.rowcount
        if deleted:
            conn.commit()
        conn.close()
        return deleted
    except Exception:
        return 0


def _clear_waves_scan_cache() -> None:
    """Delete Waves WaveShell scan caches so sub-plugin lists are rebuilt."""
    if not WAVES_SCAN_CACHE_DIR.is_dir():
        return
    for cache_file in WAVES_SCAN_CACHE_DIR.rglob("SCAN_CACHE*"):
        try:
            cache_file.unlink()
        except OSError:
            pass
    # Also clear cached WaveShell WPAPI bundles (old versions)
    wpapi_dir = WAVES_SCAN_CACHE_DIR / "Library/Audio/Plug-Ins/WPAPI"
    if wpapi_dir.is_dir():
        shutil.rmtree(wpapi_dir, ignore_errors=True)


def remove_waves_non_production(
    dest_dir: Path,
    failures: list[str] | None = None,
) -> tuple[list[str], int]:
    """Move non-production Waves plugin bundles to dest_dir."""
    moved: list[str] = []
    bytes_moved = 0

    for waves_dir in _find_waves_plugin_dirs():
        for bundle_name in WAVES_NON_PRODUCTION:
            path = waves_dir / bundle_name
            if not path.exists():
                continue
            if not ensure_dir(dest_dir):
                continue
            size = get_size(path)
            ok, error = move_path(path, dest_dir)
            if ok:
                if bundle_name not in moved:
                    moved.append(bundle_name)
                bytes_moved += size
            elif failures is not None:
                failures.append(f"{path} -> {error}")

    return moved, bytes_moved


def main():
    args = {arg.lower() for arg in sys.argv[1:]}

    strip_waves = "skipwavesmono" not in args
    remove_broken = "checkbroken" in args  # opt-in (slow)
    remove_m4l_adv = "skipm4l" not in args

    tmp_base = resolve_tmp_base(DEFAULT_TMP_PATH)
    if tmp_base != DEFAULT_TMP_PATH:
        print(f"Using temp path {tmp_base} (default not writable).")

    failures: list[str] = []
    results = {}

    # Collect AU and VST3 names for VST2/AAX/CLAP dedup (those are still
    # removed when EITHER an AU or VST3 with the same stem exists).
    sys_au_names = get_au_names(SYSTEM_COMPONENTS_PATH)
    user_au_names = get_au_names(USER_COMPONENTS_PATH)
    all_au_names = sys_au_names | user_au_names

    sys_vst3_names = get_vst3_names(SYSTEM_VST3_PATH)
    user_vst3_names = get_vst3_names(USER_VST3_PATH)
    all_vst3_names = sys_vst3_names | user_vst3_names

    preferred_names = all_au_names | all_vst3_names

    # ─────────────────────────────────────────────────────────────────
    # AU-preferred VST3 dedup, via Ableton's plugin index + on-disk
    # verification. AU is preferred (Logic only loads AU), so VST3 is
    # what moves when both formats are present. But we ONLY move a VST3
    # when:
    #   (a) Ableton's files-DB has an AU entry sharing the plugin name
    #   (b) the actual .component bundle exists on disk with matching
    #       (type, subtype, manufacturer) codes (or bundle stem)
    # Without (b), Live's DB can carry stale AU entries from old installs
    # and we'd quietly delete the only working format. AU never moves.
    # ─────────────────────────────────────────────────────────────────
    diag = ableton_diagnostics()
    if "error" in diag:
        print(f"Ableton-aware dedup: skipped ({diag['error']}).")
    else:
        print("Ableton-aware VST3 dedup diagnostics:")
        print(f"  AU bundles on disk:                    {diag['components_on_disk']}")
        print(f"  AU entries Ableton indexes:            {diag['au_names_indexed_by_live']}")
        print(f"  VST3 entries Ableton indexes:          {diag['vst3_names_indexed_by_live']}")
        print(f"  Plugins where Live shows BOTH formats: {diag['name_overlap_au_and_vst3_in_live']}")
        print(f"  Stale AU entries (no .component file): {diag['stale_au_only_in_live_db']}")
        print(f"  VST3s to move (AU verified on disk):   {diag['vst3_to_move_after_match']}")

    ableton_vst3_moved: list[str] = []
    ableton_vst3_bytes = 0
    plugins_db, vst3_shadowed = find_vst3_shadowed_by_au()
    # PREFER_VST3 exceptions: never move their VST3 — the AU twin goes instead.
    exception_kept = [p.name for p in vst3_shadowed if p.stem.lower() in PREFER_VST3]
    if exception_kept:
        vst3_shadowed = [p for p in vst3_shadowed if p.stem.lower() not in PREFER_VST3]
        print(f"Prefer-VST3 exceptions (VST3 kept): {', '.join(sorted(exception_kept))}")
    if plugins_db is None:
        print("Ableton plugin DB not found — skipping AU-preferred VST3 dedup.")
    elif vst3_shadowed:
        dest = VST3_CLEANED_PATH
        for path in vst3_shadowed:
            if plugin_base_name(path) in NEVER_REMOVE:
                continue
            if not ensure_dir(dest):
                failures.append(f"{path} -> failed to create {dest}")
                continue
            size = get_size(path)
            ok, error = move_path(path, dest)
            if ok:
                ableton_vst3_moved.append(path.name)
                ableton_vst3_bytes += size
            else:
                failures.append(f"{path} -> {error}")

    # PREFER_VST3 exceptions: move the AU twin aside (VST3 stays).
    # Exact-stem matching, so "Stellarizer MIDI FX.component" is untouched.
    # Guard: only when the VST3 actually exists on disk — otherwise the AU
    # is the only working format and must stay.
    prefer_vst3_active = {n for n in PREFER_VST3 if n in all_vst3_names}
    prefer_vst3_skipped = PREFER_VST3 - all_vst3_names
    if prefer_vst3_skipped:
        print(f"Prefer-VST3 exceptions skipped (no VST3 on disk, AU kept): "
              f"{', '.join(sorted(prefer_vst3_skipped))}")
    exc_dest = tmp_base / "AU_Prefer_VST3"
    exc_sys_moved, exc_sys_bytes = remove_duplicates_by_names(
        SYSTEM_COMPONENTS_PATH, exc_dest, ".component", prefer_vst3_active, failures,
    )
    exc_user_moved, exc_user_bytes = remove_duplicates_by_names(
        USER_COMPONENTS_PATH, exc_dest, ".component", prefer_vst3_active, failures,
    )
    exc_au_moved = exc_sys_moved + exc_user_moved
    exc_au_bytes = exc_sys_bytes + exc_user_bytes

    # System-level non-AU/non-VST3 duplicates.
    # AU is never removed. VST3 dedup happens above (Ableton-aware).
    sys_vst_moved, sys_vst_bytes = remove_duplicates_by_names(
        SYSTEM_VST_PATH,
        tmp_base / "VST",
        ".vst",
        preferred_names,
        failures,
    )
    sys_aax_moved, sys_aax_bytes = remove_duplicates_by_names(
        SYSTEM_AAX_PATH,
        tmp_base / "AAX",
        ".aaxplugin",
        preferred_names,
        failures,
    )
    sys_clap_moved, sys_clap_bytes = remove_duplicates_by_names(
        SYSTEM_CLAP_PATH,
        tmp_base / "CLAP",
        ".clap",
        preferred_names,
        failures,
    )

    # User-level non-AU/non-VST3 duplicates.
    user_vst_moved, user_vst_bytes = remove_duplicates_by_names(
        USER_VST_PATH,
        tmp_base / "VST_User",
        ".vst",
        preferred_names,
        failures,
    )
    user_aax_moved, user_aax_bytes = remove_duplicates_by_names(
        USER_AAX_PATH,
        tmp_base / "AAX_User",
        ".aaxplugin",
        preferred_names,
        failures,
    )
    user_clap_moved, user_clap_bytes = remove_duplicates_by_names(
        USER_CLAP_PATH,
        tmp_base / "CLAP_User",
        ".clap",
        preferred_names,
        failures,
    )

    # Waves-specific: old WaveShell versions (always remove)
    waves_old_moved, waves_old_bytes = remove_hardcoded_files(
        WAVES_OBSOLETE,
        tmp_base / "Waves_Obsolete",
        failures,
    )

    # Waves non-production plugins
    waves_np_moved, waves_np_bytes = remove_waves_non_production(
        tmp_base / "Waves_Non_Production",
        failures,
    )

    # FabFilter: remove older plugin versions (e.g. Pro-Q 2 when Pro-Q 3 exists)
    all_plugin_dirs = [
        SYSTEM_VST3_PATH, SYSTEM_VST_PATH, SYSTEM_COMPONENTS_PATH,
        SYSTEM_AAX_PATH, SYSTEM_CLAP_PATH,
        USER_VST3_PATH, USER_VST_PATH, USER_COMPONENTS_PATH,
        USER_AAX_PATH, USER_CLAP_PATH,
    ]
    ff_moved: list[str] = []
    ff_bytes = 0
    ff_dest = tmp_base / "FabFilter_Old_Versions"
    for path in find_obsolete_fabfilter(all_plugin_dirs):
        if not ensure_dir(ff_dest):
            continue
        size = get_size(path)
        ok, error = move_path(path, ff_dest)
        if ok:
            ff_moved.append(path.name)
            ff_bytes += size
        else:
            failures.append(f"{path} -> {error}")

    # Revoice Pro: remove the legacy VST3 bundle when the modern
    # RevoiceProLink (AU or VST3) is installed.
    revoice_moved: list[str] = []
    revoice_bytes = 0
    revoice_dest = tmp_base / "Revoice_Legacy"
    for path in find_obsolete_revoice(all_plugin_dirs):
        if not ensure_dir(revoice_dest):
            continue
        size = get_size(path)
        ok, error = move_path(path, revoice_dest)
        if ok:
            revoice_moved.append(path.name)
            revoice_bytes += size
        else:
            failures.append(f"{path} -> {error}")

    # Broken codesign — plugins macOS will refuse to load.
    # Verification is slow (parallelized at 10 workers, capped at 10s per
    # plugin). Off by default; enable with 'checkbroken'.
    broken_moved: list[str] = []
    broken_bytes = 0
    broken_dest = tmp_base / "Broken_Codesign"
    if remove_broken:
        for path, reason in find_broken_codesign(all_plugin_dirs):
            if plugin_base_name(path) in NEVER_REMOVE:
                continue
            if not ensure_dir(broken_dest):
                continue
            size = get_size(path)
            ok, error = move_path(path, broken_dest)
            if ok:
                broken_moved.append(f"{path.name} — {reason}")
                broken_bytes += size
            else:
                failures.append(f"{path} -> {error}")

    # Max for Live: .adv presets shadowed by a same-named .amxd device.
    # User Library is auto-detected from Live's `Live-files-NNNNN.db`
    # — no hardcoded paths, no filesystem scan.
    m4l_moved: list[str] = []
    m4l_bytes = 0
    m4l_user_lib: Path | None = None
    if remove_m4l_adv:
        m4l_user_lib, m4l_matches = find_redundant_m4l_adv()
        if m4l_user_lib is not None:
            print(f"Max for Live User Library: {m4l_user_lib}")
            if m4l_matches:
                m4l_dest = tmp_base / "M4L_adv_dupes"
                for adv_path, amxd_name in m4l_matches:
                    if not ensure_dir(m4l_dest):
                        continue
                    size = get_size(adv_path)
                    ok, error = move_path(adv_path, m4l_dest)
                    if ok:
                        m4l_moved.append(f"{adv_path.name} — shadowed by {amxd_name}")
                        m4l_bytes += size
                    else:
                        failures.append(f"{adv_path} -> {error}")
        else:
            print("Max for Live: Live database not found — skipping .adv dedup.")

    # Waves mono sub-component stripping (runs by default)
    waves_mono_removed = 0
    waves_mono_plugins = 0
    ableton_deleted = 0
    if strip_waves:
        waves_mono_plugins, waves_mono_removed = strip_waves_mono()
        ableton_deleted = clear_ableton_waves_redundant()

    # Combine results
    results["VST3 shadowed by AU (Ableton)"] = (ableton_vst3_moved, ableton_vst3_bytes)
    results["AU removed (VST3 preferred)"] = (exc_au_moved, exc_au_bytes)
    results["VST2 dupes (System)"] = (sys_vst_moved, sys_vst_bytes)
    results["VST2 dupes (User)"] = (user_vst_moved, user_vst_bytes)
    results["AAX dupes (System)"] = (sys_aax_moved, sys_aax_bytes)
    results["AAX dupes (User)"] = (user_aax_moved, user_aax_bytes)
    results["CLAP dupes (System)"] = (sys_clap_moved, sys_clap_bytes)
    results["CLAP dupes (User)"] = (user_clap_moved, user_clap_bytes)
    results["Waves old versions"] = (waves_old_moved, waves_old_bytes)
    results["Waves non-production"] = (waves_np_moved, waves_np_bytes)
    results["FabFilter old versions"] = (ff_moved, ff_bytes)
    results["Revoice Pro legacy"] = (revoice_moved, revoice_bytes)
    results["Broken codesign"] = (broken_moved, broken_bytes)
    results["M4L .adv shadowed by .amxd"] = (m4l_moved, m4l_bytes)

    total_bytes = sum(b for _, b in results.values())
    total_count = sum(len(m) for m, _ in results.values())

    if total_count == 0 and waves_mono_removed == 0 and ableton_deleted == 0:
        if failures:
            print(f"Found duplicates but failed to move {len(failures)} item(s).")
            for entry in failures:
                print(f"  - {entry}")
        else:
            print("Nothing to clean. No duplicate formats or Waves mono redundancies found.")
    else:
        if total_count:
            print(f"Moved {total_count} plugin(s) ({human_size(total_bytes)})")
            if ableton_vst3_moved:
                print(f"  VST3 shadowed by AU -> {VST3_CLEANED_PATH}")
            if total_count > len(ableton_vst3_moved):
                print(f"  Other cleaned items  -> {tmp_base}")
            print()

        for category, (moved, _) in results.items():
            if moved:
                print(f"{category} ({len(moved)}):")
                for name in moved:
                    print(f"  - {name}")
                print()

        if waves_mono_removed:
            print(f"Waves mono stripped ({waves_mono_removed}):")
            print(f"  Removed {waves_mono_removed} mono definition(s) from {waves_mono_plugins} plugin(s)\n")

        if ableton_deleted:
            print(f"Ableton plugin database:")
            print(f"  Removed {ableton_deleted} Waves mono/surround entries from Live database\n")

        if failures:
            print(f"Failed to move {len(failures)} item(s):")
            for entry in failures:
                print(f"  - {entry}")
            print()

    if not strip_waves:
        print("Skipping Waves mono stripping ('skipwavesmono' was specified).")
    if not remove_broken:
        print("Codesign verification not run (pass 'checkbroken' to enable — slow).")
    if not remove_m4l_adv:
        print("Skipping Max for Live .adv dedup ('skipm4l' was specified).")



def _plugin_ext_label(ext: str) -> str:
    return {".vst": "VST2", ".vst3": "VST3", ".component": "AU",
            ".clap": "CLAP", ".aaxplugin": "AAX"}.get(ext, ext)


def _sane_timestamp(t: float, fallback: float = 0.0) -> float:
    """Clamp bogus filesystem timestamps into a range time_t can format.

    Some plugin bundles carry corrupt birthtimes (huge, negative, or NaN),
    which blow up datetime.fromtimestamp() with OverflowError/OSError/ValueError.
    """
    for candidate in (t, fallback):
        try:
            value = float(candidate)
        except (TypeError, ValueError):
            continue
        if value != value:  # NaN
            continue
        try:
            datetime.fromtimestamp(value)
        except (OverflowError, OSError, ValueError):
            continue
        return value
    return 0.0


def _fmt_timestamp(t: float) -> str:
    try:
        return datetime.fromtimestamp(t).strftime("%Y-%m-%d %H:%M")
    except (OverflowError, OSError, ValueError):
        return "unknown"


def list_recent_plugins(limit: int = 50) -> None:
    """Print the most recently installed plugins across all directories."""
    plugin_exts = {".vst", ".vst3", ".component", ".clap", ".aaxplugin"}
    dirs = [
        SYSTEM_VST_PATH, SYSTEM_VST3_PATH, SYSTEM_COMPONENTS_PATH,
        SYSTEM_CLAP_PATH, SYSTEM_AAX_PATH,
        USER_VST_PATH, USER_VST3_PATH, USER_COMPONENTS_PATH,
        USER_CLAP_PATH, USER_AAX_PATH,
    ]
    plugins: list[tuple[Path, float]] = []
    for d in dirs:
        if not d.is_dir():
            continue
        for root, subdirs, _ in os.walk(d):
            matched = []
            for name in subdirs:
                if Path(name).suffix.lower() in plugin_exts:
                    full = Path(root) / name
                    try:
                        st = full.stat()
                        t = getattr(st, "st_birthtime", None) or st.st_mtime
                    except OSError:
                        continue
                    t = _sane_timestamp(t, fallback=getattr(st, "st_mtime", 0.0))
                    plugins.append((full, t))
                    matched.append(name)
            for m in matched:
                subdirs.remove(m)

    plugins.sort(key=lambda x: x[1], reverse=True)
    top = plugins[:limit]
    if not top:
        return

    max_name = max(len(p.stem) for p, _ in top)
    max_type = max(len(_plugin_ext_label(p.suffix.lower())) for p, _ in top)

    print(f"\n{'#':>3}  {'Plugin':<{max_name}}  {'Type':<{max_type}}  Installed")
    print(f"{'─'*3}  {'─'*max_name}  {'─'*max_type}  {'─'*19}")
    for i, (p, t) in enumerate(top, 1):
        dt = _fmt_timestamp(t)
        print(f"{i:>3}  {p.stem:<{max_name}}  {_plugin_ext_label(p.suffix.lower()):<{max_type}}  {dt}")


# ---------------------------------------------------------------------------
# macOS CrashReporter dialog toggle
# ---------------------------------------------------------------------------
# Some plugins (e.g. Eventide Blackhole Immersive 1.3.0) double-free at
# Ableton Live's exit-time static destruction. Live has already flushed
# prefs/project state and returned GlobalExit(): End (0) by then — the
# SIGABRT is purely cosmetic. Suppress the "Live quit unexpectedly" dialog
# by setting CrashReporter's DialogType to 'none'. Logs are still written
# to ~/Library/Logs/DiagnosticReports/.
CRASH_REPORTER_DOMAIN = "com.apple.CrashReporter"
CRASH_REPORTER_KEY = "DialogType"


def configure_crash_reporter(enable: bool) -> None:
    """Toggle macOS CrashReporter dialog.

    enable=False -> 'none'   (suppress quit-unexpectedly popups; default)
    enable=True  -> 'prompt' (restore system default)
    """
    desired = "prompt" if enable else "none"

    current: str | None = None
    try:
        probe = subprocess.run(
            ["defaults", "read", CRASH_REPORTER_DOMAIN, CRASH_REPORTER_KEY],
            capture_output=True, text=True, check=False,
        )
        if probe.returncode == 0:
            current = probe.stdout.strip()
    except Exception:
        pass

    bar = "=" * 60
    print()
    print(bar)
    print("macOS CrashReporter dialog")
    print(bar)
    print(f"  domain : {CRASH_REPORTER_DOMAIN}")
    print(f"  key    : {CRASH_REPORTER_KEY}")
    print(f"  before : {current if current is not None else '<unset>'}")
    print(f"  after  : {desired}")

    if current == desired:
        print(f"  status : already set to '{desired}', no change.")
    else:
        try:
            subprocess.run(
                ["defaults", "write", CRASH_REPORTER_DOMAIN,
                 CRASH_REPORTER_KEY, desired],
                check=True,
            )
            verb = "Enabled" if enable else "Suppressed"
            print(f"  status : {verb} crash reporter dialog.")
        except subprocess.CalledProcessError as exc:
            print(f"  status : FAILED ({exc})")
            return

    if enable:
        print("  effect : 'Live quit unexpectedly' popups will appear again.")
    else:
        print("  effect : Harmless quit crashes (e.g. Eventide Blackhole")
        print("           Immersive destructor bug) no longer pop a dialog.")
        print("           Crash logs still written to")
        print("           ~/Library/Logs/DiagnosticReports/.")
        print("  revert : vst_cleaner.py --enable-crash-reporter")
    print(bar)


if __name__ == "__main__":
    enable_crash_reporter = "--enable-crash-reporter" in sys.argv
    # Strip so main()'s lowercase arg-set doesn't carry it around.
    sys.argv = [a for a in sys.argv if a != "--enable-crash-reporter"]

    # Read-only subcommands — print and exit, no cleanup, no side effects.
    early_args = {a.lower() for a in sys.argv[1:]}
    if "usage" in early_args:
        print_usage_report(min_count=10)
        sys.exit(0)

    main()
    list_recent_plugins()
    # Run last so it's the final verbose block the user sees.
    configure_crash_reporter(enable=enable_crash_reporter)
