# ============================================================
# Packer plugin requirements
# `packer init` reads this and downloads the GCP + Ansible plugins.
# ============================================================
packer {
  required_plugins {
    googlecompute = {
      version = ">= 1.1.4"
      source  = "github.com/hashicorp/googlecompute"
    }
    ansible = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

# ============================================================
# Input variables
# Override at build time: `packer build -var "project_id=my-proj" .`
# ============================================================
variable "project_id" {
  type        = string
  description = "GCP project ID where the image is built and stored."
  # No default → forces you to pass it, avoiding building in the wrong project.
}

variable "zone" {
  type    = string
  default = "asia-south1-a" # Mumbai
}

variable "machine_type" {
  type    = string
  default = "e2-small"
}

variable "image_prefix" {
  type    = string
  default = "ansible-controller"
}

# Unique, sortable suffix so each image name is distinct.
locals {
  timestamp = formatdate("YYYYMMDD-hhmmss", timestamp())
}

# ============================================================
# SOURCE (builder)
# Launches a temporary Compute Engine VM from a base image family,
# runs provisioners, then snapshots it into a new Compute Image.
# ============================================================
source "googlecompute" "ubuntu" {
  project_id   = var.project_id
  zone         = var.zone
  machine_type = var.machine_type
  ssh_username = "packer" # Packer creates this temp user on the build VM

  # Pull the LATEST Ubuntu 22.04 LTS from the official family
  # instead of pinning a stale image name.
  source_image_family = "ubuntu-2204-lts"
  # The image family is published by Canonical's public project.
  # (For ubuntu-os-cloud images you usually don't set source_image_project_id,
  #  but it can be set to "ubuntu-os-cloud" to be explicit.)

  # Final image name (must be unique → timestamp).
  image_name        = "${var.image_prefix}-${local.timestamp}"
  image_description = "Ubuntu 22.04 baked with Ansible via Packer"

  # Group built images under your own family so Terraform can later
  # look up "the newest image in this family" instead of an exact name.
  image_family = var.image_prefix

  # Networking: default network works out of the box; override for a custom VPC.
  network = "default"
  # subnetwork = "your-subnet"   # required if using a custom-mode VPC
  # use_internal_ip = false      # set true + Cloud NAT for no public IP

  # Labels (GCP's equivalent of AWS tags) on the resulting image.
  image_labels = {
    base_os     = "ubuntu-2204"
    built_by    = "packer"
    provisioner = "ansible"
    owner       = env("hostname") # read system env variable 
  }
}

# ============================================================
# BUILD
# Identical to the AWS version — only the source changed.
# ============================================================
build {
  name    = "ansible-controller-image"
  sources = ["source.googlecompute.ubuntu"]

  # ----- Step 1: wait for cloud-init, refresh apt -----
  provisioner "shell" {
    inline = [
      "echo 'Waiting for cloud-init to finish...'",
      "cloud-init status --wait",
      "sudo apt-get update -y"
    ]
  }

  # ----- Step 2: run Ansible against the temp instance -----
  # Packer auto-generates the inventory; no hosts file needed.
  provisioner "ansible" {
    playbook_file = "./playbook.yml"
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
