/**
 * Copyright 2022 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
// Set up the project used for hosting the first application
resource "google_project" "appProject1" {
  name       = "appProject1"
  project_id = "app-project1-${random_id.randomProjectSuffix.dec}"
  folder_id = google_folder.disconnected.name
  billing_account = var.billingID
  auto_create_network = false
}
// Because we will be using PSC in this project to
// publish our application , multiple API's
// need to be enabled
resource "google_project_service" "appAPI" {
    for_each = toset(var.app_service_list)
    project = google_project.appProject1.id
    service = each.key
}
// Create the VPC
resource "google_compute_network" "appProject1VPC" {
  project                 = google_project.appProject1.number
  name                    = "app"
  auto_create_subnetworks = false
  routing_mode            = "GLOBAL"
  depends_on = [ google_project_service.appAPI ]
}
// Create the subnet for the application servers
resource "google_compute_subnetwork" "appComputeSubnet" {
  name          = "app-compute"
  ip_cidr_range = var.appSubnet
  region        = var.region
  project       = google_project.appProject1.number
  network       = google_compute_network.appProject1VPC.self_link
}
// Create the subnet that PSC will use to proxy 
// conections to the application via a forwaring
// rule in the application subnet
resource "google_compute_subnetwork" "appPscsubnet" {
  name          = "app-psc"
  ip_cidr_range = var.appPscSubnet
  region        = var.region
  project       = google_project.appProject1.number
  network       = google_compute_network.appProject1VPC.self_link
  purpose       = "PRIVATE_SERVICE_CONNECT"
}
// Create a FW rule to allow health checks for the
// load balancer
resource "google_compute_firewall" "health-check-app1" {
  name    = "health-check-app1"
  project = google_project.appProject1.number
  network = google_compute_network.appProject1VPC.name
  source_ranges = [ "35.191.0.0/16", "130.211.0.0/22" ]
  allow {
    protocol = "tcp"
    ports = [ "8080" ]
  }
}
// Create a FW rule that allows connections to the
// application from the PSC proxy subnet we created earlier
resource "google_compute_firewall" "app1-psc" {
  name    = "app-psc"
  project = google_project.appProject1.number
  network = google_compute_network.appProject1VPC.name
  #source_ranges = [ "192.168.2.0/24", "172.25.16.0/24" ]
  source_ranges = [ "172.25.16.0/24" ]
  allow {
    protocol = "tcp"
    ports = [ "8080" ]
  }
}
// Create a FW rule for SSH to the app servers
resource "google_compute_firewall" "ssh-app1" {
  name    = "ssh-branch"
  project = google_project.appProject1.number
  network = google_compute_network.appProject1VPC.name
  source_ranges = [ "35.235.240.0/20" ]
  allow {
    protocol = "tcp"
    ports = [ "22" ]
  }
}
// Create a GCS bucket to upload our nginx config and
// basic index page to, the app servers will fetch
// this data upon startup
resource "google_storage_bucket" "app1-data" {
  name          = "app-project1-${random_id.randomProjectSuffix.dec}-data"
  project       = google_project.appProject1.number
  location      = var.region
  force_destroy = true
  uniform_bucket_level_access = true
}
// Bundle up the files for nginx
data "archive_file" "source" {
  type        = "zip"
  source_dir  = "appdata/app1/"
  output_path = "appdata/app1.zip"
}
// Upload the bundled archive to the bucket
// Append file MD5 to force bucket to be recreated on zip change
resource "google_storage_bucket_object" "app1-zip" {
  name   = "app1.zip"
  bucket = google_storage_bucket.app1-data.name
  source = data.archive_file.source.output_path
}
// Create the service account for the app servers
resource "google_service_account" "app1_service_account" {
  project      = google_project.appProject1.project_id
  account_id   = "app1sa"
  display_name = "app1sa"
}
// Modify the bucket policy to allow access
resource "google_storage_bucket_iam_binding" "app1-reader" {
    bucket      = google_storage_bucket.app1-data.name
    role        = "roles/storage.objectViewer"
    members = [
      "serviceAccount:${google_service_account.app1_service_account.email}",
    ]
  }
// Define the image to use in MIG
data "google_compute_image" "debian_image" {
  family   = "debian-11"
  project  = "debian-cloud"
}
// Managed Instance Group for App1
resource "google_compute_instance_template" "app1-instance-template" {
  machine_type = "f1-micro"
  project = google_project.appProject1.number
   lifecycle {
    ignore_changes = [metadata["ssh-keys"]]
    create_before_destroy = true
  }
  name_prefix = "app1-"
  service_account {
    email = google_service_account.app1_service_account.email
    scopes = ["cloud-platform"]
  }
  network_interface {
    network    = google_compute_network.appProject1VPC.self_link
    subnetwork = google_compute_subnetwork.appComputeSubnet.self_link

    access_config {
    }
  }
  metadata_startup_script = <<SCRIPT
    apt-get update
    apt-get upgrade -y
    apt-get install -y nginx unzip
    mkdir /apptemp 
    cd /apptemp
    gsutil cp ${google_storage_bucket.app1-data.url}/app1.zip .
    unzip app1.zip
    cd app1
    mv nginx.conf /etc/nginx/
    mv nginx-default.conf /etc/nginx/sites-enabled/
    echo "This is a server in the ${google_project.appProject1.name} project" > /var/www/html/index.html
    service nginx restart
    SCRIPT
  disk {
    source_image = data.google_compute_image.debian_image.self_link
    auto_delete  = true
    boot         = true
  }
}
// Instance Group Manager
resource "google_compute_region_instance_group_manager" "app1" {
  project = google_project.appProject1.number
  region   = var.region
  name     = "app1-rigm"
  version {
    instance_template = google_compute_instance_template.app1-instance-template.self_link
    name              = "primary"
  }
  base_instance_name = "rigm"
  target_size        = 1
}
// Health Check for App1
resource "google_compute_region_health_check" "app" {
  project = google_project.appProject1.number
  region = var.region
  name   = "app-health-check"
  check_interval_sec = 1
  timeout_sec = 1
  tcp_health_check {
    port = "8080"
  }
}
// Create the ILB backend for App1
resource "google_compute_region_backend_service" "app1" {
  project = google_project.appProject1.number
  load_balancing_scheme = "INTERNAL"
  backend {
    group          = google_compute_region_instance_group_manager.app1.instance_group
  }
  region      = var.region
  name        = "app-service"
  timeout_sec = 10
  health_checks = [google_compute_region_health_check.app.self_link]
}
// Create the ILB forwarding rule for App1 
resource "google_compute_forwarding_rule" "app1" {
  name                  = "app1-forwarding-rule"
  project               = google_project.appProject1.number
  region                = var.region
  load_balancing_scheme = "INTERNAL"
  backend_service       = google_compute_region_backend_service.app1.self_link
  ports                 = ["8080"]
  ip_address            = "192.168.2.20"
  network               = google_compute_network.appProject1VPC.name
  subnetwork            = google_compute_subnetwork.appComputeSubnet.name
}
// Create the PSC service attachement to advertise App1
resource "google_compute_service_attachment" "app1_service_attachment" {
  name        = "app1-service-attachment"
  region      = var.region
  project     = google_project.appProject1.number
  enable_proxy_protocol    = true
  connection_preference    = "ACCEPT_AUTOMATIC"
  nat_subnets              = [google_compute_subnetwork.appPscsubnet.self_link]
  target_service           = google_compute_forwarding_rule.app1.self_link
}