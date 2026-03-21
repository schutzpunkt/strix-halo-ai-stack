# strix-halo-ai-stack

Ansible playbook to configure AMD Strix Halo machines (e.g. Framework Desktop or GMKtec EVO-X2) as local AI inference servers running Fedora 43. Sets up [llama.cpp](github.com/ggml-org/llama.cpp) with [llama-swap](https://github.com/mostlygeek/llama-swap) and [Open WebUI](https://github.com/open-webui/open-webui) and downloads GGUF models. With NGINX reverse proxy and TLS via ACME (using [step-ca](https://github.com/smallstep/certificates)) or self-signed CA.

## Credits

This project relies on [amd-strix-halo-toolboxes](https://github.com/kyuz0/amd-strix-halo-toolboxes) by **kyuz0**. Pre-built Toolbox containers with ROCm and Vulkan support for AMD Strix Halo APUs. Without that work, running llama.cpp with full GPU offload on this hardware would be significantly more involved. Huge thanks to kyuz0 for putting that together.

---

## Prerequisites

- A machine with an AMD Strix Halo APU (128 GB unified memory)
- Ansible installed on your local machine
- SSH access to the target host

---

## Setup Steps

### 1. Install Fedora 43 Server Edition

Install [Fedora 43 Server](https://fedoraproject.org/server/) on the target machine. During installation, create a sudo-capable user (default assumed: `fedora`).

> The playbook targets Fedora 43. Other Fedora versions may work but are untested.

---

### 2. Add Your SSH Public Key to the Sudo User

From your local machine, copy your public key to the remote host:

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub fedora@<host-ip>
```

Verify passwordless SSH access works before continuing:

```bash
ssh -i ~/.ssh/id_ed25519 fedora@<host-ip>
```

---

### 3. Set Up DNS or `/etc/hosts`

The playbook assigns a hostname and domain to the target (e.g. `framework.lan`). You need to resolve this name from your local machine.

**Option A — `/etc/hosts` (simplest):**

Add entries to `/etc/hosts` on your local machine:

```
192.168.12.70   framework.lan
192.168.12.70   openwebui.framework.lan
192.168.12.70   llamaswap.framework.lan
```

**Option B — Local DNS:**

Add A records in your local DNS resolver for all three names pointing to the host's IP:

```
framework.lan
openwebui.framework.lan
llamaswap.framework.lan
```

> The hostname and domain are set per-host in `inventory/main.yml` via `strixhalo_hostname` and `strixhalo_domain`.

---

### 4. Edit the Inventory File

Open [`inventory/main.yml`](inventory/main.yml) and update it for your host:

```yaml
all:
  children:
    strixhalos:
      hosts:
        strixhalo1:
          ansible_host: 192.168.12.70         # IP of your target machine
          ansible_user: fedora                 # SSH user (sudo capable)
          ansible_ssh_private_key_file: ~/.ssh/id_ed25519  # your private key
          strixhalo_hostname: framework        # hostname (without domain)
          strixhalo_domain: lan                # local domain
```

---

### 5. Edit the Variables File

Open [`group_vars/all/vars.yml`](group_vars/all/vars.yml) and configure:

```yaml
# --- TLS / CA ---

# Option A: ACME (requires a running step-ca or other ACME server)
ansible_ca_acme_url: https://stepca.example.lan/acme/acme/directory
ansible_ca_root_crt: "{{ playbook_dir }}/files/step-ca/root_ca.crt"
ansible_ca_acme_email: "{{ ansible_hostname }}@example.com"

# Option B: Self-signed CA (comment out Option A and uncomment these)
# ansible_ca_root_crt: "{{ playbook_dir }}/files/step-ca/root_ca.crt"
# ansible_ca_root_key: "{{ playbook_dir }}/files/step-ca/root_ca.key"
# The playbook auto-generates the key/cert pair on first run if absent.

# --- llama-swap API Key (optional) ---
# Protects the llama-swap API and UI. Leave empty to disable auth.
# Generate one with: echo "sk-$(head -c 48 /dev/urandom | base64)"
strixhalo_llama_swap_openai_api_key: ""

# --- Open WebUI Admin Account ---
strixhalo_open_webui_admin_email: "openwebui@example.com"
strixhalo_open_webui_admin_password: "changeme"  # only applied on first run
```

> Set exactly **one** CA mode. Defining both `ansible_ca_root_key` and `ansible_ca_acme_url` at the same time will cause the playbook to fail.

---

### 6. Install Ansible

On your local machine:

```bash
# Fedora / RHEL
sudo dnf install ansible

# Debian / Ubuntu
sudo apt install ansible

# pip (any OS)
pip install ansible
```

Then install the required Ansible collections:

```bash
ansible-galaxy install -r requirements.yml
```

---

### 7. Run the Playbook

```bash
ansible-playbook playbook.yml -K
```

`-K` prompts for the sudo (BECOME) password of the remote user.

> **After the first successful run, reboot the target machine.** The playbook modifies kernel parameters (GRUB cmdline) for AMD IOMMU and GPU VRAM settings — these only take effect after a reboot.


---

## Updating Packages and Toolboxes

By default, `dnf update` and toolbox image refreshes are **skipped** on every run. To trigger them explicitly, pass `--tags update`:

```bash
ansible-playbook playbook.yml -K --tags update
```

> **Do not run `--tags update` unnecessarily.** Toolbox images are several GB each and are pulled from a public registry — pulling them too frequently will get you rate limited. Beyond bandwidth, not every kernel version is compatible with every ROCm release or firmware version. Only update when you have a specific reason to (e.g. a new ROCm toolbox was released and your kernel supports it).

---

## Configuring Models

### Which models get served — `config.yaml.j2`

The llama-swap configuration is templated from:

```
roles/strixhalo/templates/config.yaml.j2
```

Edit this file to add, remove, or adjust model entries in the `models:` section. Each model entry defines the binary invocation, context size, GPU layers, sampling parameters, and an optional `cmdStop`. Models are grouped under `groups.main` with `swap: true` so only one model is loaded at a time.

See the [llama-swap config example](https://github.com/mostlygeek/llama-swap/blob/main/config.example.yaml) for full documentation of all available options.

### Which model files get downloaded — `strixhalo/vars/main.yml`

Model files are downloaded from the URLs listed in:

```
roles/strixhalo/vars/main.yaml
```

Add or remove Hugging Face (or other direct) URLs under `model_urls:`:

```yaml
model_urls:
  - "https://huggingface.co/bartowski/some-model-GGUF/resolve/main/model.gguf"
```

Files are saved to `~/models/` on the target host. Multi-part GGUF splits (e.g. `-00001-of-00003.gguf`) are all listed individually — llama.cpp loads the first shard automatically.

---

## Accessing the Services

Once the playbook completes, the following are available (replace `framework.lan` with your configured hostname + domain):

| Service | URL |
|---|---|
| Fedora Web Console | `https://framework.lan` |
| Open WebUI | `https://openwebui.framework.lan` |
| llama-swap API | `https://llamaswap.framework.lan` |

Log in to Open WebUI with the admin credentials set in `group_vars/all/vars.yml`.
