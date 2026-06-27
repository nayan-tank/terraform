# Packer 

HashiCorp Packer is an open-source tool for building **machine images** (and container images) from a single source configuration. The core idea: you define how an image should be configured once, and Packer produces identical, pre-baked images across multiple platforms automatically.

**The problem it solves**

Normally you'd boot a base OS image, then configure it at launch time — installing packages, copying files, applying settings (the "configure on boot" model). That's slow and can drift. Packer flips this to an "immutable infrastructure" model: you bake everything into the image *ahead of time*, so when you launch an instance it's already fully configured and boots fast and consistently.

**How it works — three main stages**

A Packer build typically involves:

*Builders* — these spin up a temporary instance/VM on a target platform, run your provisioning steps against it, then snapshot the result into a final image. There are builders for AWS AMIs, Azure Managed Images, GCP images, VMware, VirtualBox, Docker, QEMU, and many more. One template can target several builders at once.

*Provisioners* — these do the actual configuration on the temporary instance: running shell scripts, or invoking Ansible, Chef, Puppet, etc. This is where you install software and apply settings.

*Post-processors* — optional steps that act on the artifact after it's built, like compressing it, tagging it, uploading it somewhere, or importing it into a registry.

**Configuration format**

Modern Packer uses HCL2 (the same language as Terraform) in `.pkr.hcl` files; older versions used JSON. A template declares source blocks (builders) and a build block listing the provisioners and post-processors to run.

**Typical workflow**

```
packer init      # download required plugins
packer validate  # check the template
packer build     # build the image(s)
```

**How it fits with Terraform and Ansible**

People often confuse these since they're all HashiCorp-adjacent or config-related, but they occupy different stages:

- **Packer** *bakes* the image (build time) — produces a golden AMI/image with software pre-installed.
- **Terraform** *provisions* infrastructure (deploy time) — launches instances *from* that Packer-built image, sets up networking, etc.
- **Ansible** *configures* running systems (runtime) — though it's also frequently used *inside* Packer as a provisioner during the bake.

A common pattern in your kind of setup: Packer builds a golden image with Ansible baked in or pre-installed, Terraform launches EC2 nodes from that AMI, and the result is faster, more consistent provisioning than configuring each node from scratch on boot.

Here's a complete, working example that builds an Ubuntu AWS AMI with Ansible baking in the configuration during the build. I'll explain the structure, then give you the files.

## How the pieces connect

```
packer build
   │
   ├─ source block (amazon-ebs)  → launches a temp EC2 instance from a base Ubuntu AMI
   │
   ├─ provisioner "ansible"      → runs playbook.yml against that temp instance
   │
   └─ snapshot                   → bakes the result into a new AMI you can launch later
```

The temp instance is throwaway — Packer terminates it after snapshotting. What you keep is the AMI.

Let me create the files.

## Key things to understand

**`source_ami_filter` instead of a hardcoded AMI ID** — AMI IDs differ per region and get deprecated. The filter picks the newest official Canonical Ubuntu 22.04 image automatically, with `owners = ["099720109477"]` being Canonical's account ID (this prevents picking up a malicious community AMI with a matching name).

**Packer auto-generates the Ansible inventory** — this is the part that ties back to your earlier question. In your Terraform setup you wrote `hosts.cfg` by hand via `templatefile` because Terraform launches *persistent* nodes that Ansible targets later. Here it's the opposite: the `ansible` provisioner runs against the *single ephemeral build host*, and Packer injects the SSH connection details itself, so `hosts: all` just works — no inventory file needed.

**Immutability payoff** — whatever `playbook.yml` installs is frozen into the AMI. When Terraform later launches instances from this AMI, Ansible and your base packages are already present, so boot is fast and every node is identical.

## To run it

```bash
packer init .          # downloads the amazon + ansible plugins
packer fmt .           # auto-format HCL
packer validate .      # syntax + config check
packer build .         # build the AMI (needs AWS creds + Ansible installed locally)
```

Prerequisites on your build machine: AWS credentials configured (env vars or `~/.aws/credentials`) and Ansible installed locally, since Packer's `ansible` provisioner shells out to your local `ansible-playbook`.

One design note: the source instance needs a default VPC/subnet with outbound internet, or you must specify `vpc_id` and `subnet_id` explicitly in the source block — worth knowing if you're building inside a custom VPC.

Want me to extend this so Terraform consumes the resulting AMI via a `data "aws_ami"` lookup, closing the Packer → Terraform → Ansible loop end to end?


```
aws_ubuntu.pkr
# ============================================================
# Packer plugin requirements
# Modern Packer (1.7+) keeps builders/provisioners as plugins.
# `packer init` reads this block and downloads them.
# ============================================================
packer {
  required_plugins {
    amazon = {
      version = ">= 1.2.8"
      source  = "github.com/hashicorp/amazon"
    }
    ansible = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

# ============================================================
# Input variables
# Override at build time: `packer build -var "region=us-east-1" .`
# ============================================================
variable "region" {
  type    = string
  default = "ap-south-1" # Mumbai
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "ami_prefix" {
  type    = string
  default = "ansible-controller"
}

# A timestamp so each built AMI has a unique, sortable name.
locals {
  timestamp = formatdate("YYYYMMDD-hhmmss", timestamp())
}

# ============================================================
# SOURCE (builder)
# Spins up a temporary EBS-backed EC2 instance from a base AMI,
# lets provisioners configure it, then snapshots it to a new AMI.
# ============================================================
source "amazon-ebs" "ubuntu" {
  region        = var.region
  instance_type = var.instance_type
  ssh_username  = "ubuntu" # default login user for Ubuntu AMIs

  # Final AMI name (must be unique in the region → timestamp).
  ami_name = "${var.ami_prefix}-${local.timestamp}"

  # Dynamically pick the LATEST official Canonical Ubuntu 22.04 AMI
  # instead of hardcoding an ami-xxxx that goes stale.
  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["099720109477"] # Canonical's AWS account ID
  }

  # Tags applied to the resulting AMI.
  tags = {
    Name        = "${var.ami_prefix}-${local.timestamp}"
    Base_OS     = "Ubuntu 22.04"
    Built_By    = "Packer"
    Provisioner = "Ansible"
  }
}

# ============================================================
# BUILD
# Ties a source to the provisioning steps that run on it.
# ============================================================
build {
  name    = "ansible-controller-image"
  sources = ["source.amazon-ebs.ubuntu"]

  # ----- Step 1: wait for cloud-init, refresh apt -----
  # On fresh Ubuntu, cloud-init may still hold the apt lock.
  provisioner "shell" {
    inline = [
      "echo 'Waiting for cloud-init to finish...'",
      "cloud-init status --wait",
      "sudo apt-get update -y"
    ]
  }

  # ----- Step 2: run Ansible against the temp instance -----
  # Packer auto-generates the inventory pointing at the build host,
  # so you do NOT write a hosts file here — Packer handles SSH.
  provisioner "ansible" {
    playbook_file = "./playbook.yml"

    # Avoids SSH host-key prompts against the ephemeral instance.
    extra_arguments = [
      "--extra-vars", "ansible_python_interpreter=/usr/bin/python3"
    ]
  }

  # ----- Step 3 (optional): emit a manifest of what was built -----
  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }
}
```


---
```
# playbook.yml
# ============================================================
# Runs INSIDE the Packer build, against the temporary EC2 host.
# Whatever this installs/configures gets baked into the final AMI.
# `hosts: all` works because Packer feeds Ansible its own inventory.
# ============================================================
- name: Configure Ansible controller image
  hosts: all
  become: true # run tasks with sudo

  tasks:
    - name: Install base packages
      ansible.builtin.apt:
        name:
          - python3-pip
          - git
          - curl
          - unzip
        state: present
        update_cache: true

    - name: Install Ansible itself (so this AMI can act as a controller)
      ansible.builtin.pip:
        name: ansible
        state: present

    - name: Create a working directory for playbooks
      ansible.builtin.file:
        path: /opt/ansible
        state: directory
        owner: ubuntu
        group: ubuntu
        mode: "0755"

    - name: Drop a marker file so you can confirm the bake worked
      ansible.builtin.copy:
        dest: /etc/image-build-info.txt
        content: |
          Image built by Packer + Ansible
          Build time: {{ ansible_date_time.iso8601 }}
        mode: "0644"
```
