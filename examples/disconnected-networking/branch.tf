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
// Setup the project used to mimic a remote branch office
resource "google_project" "branchProject" {
  name       = var.branchProjectName
  project_id = "${var.branchProjectName}-${random_id.randomProjectSuffix.dec}"
  folder_id = google_folder.disconnected.name
  billing_account = var.billingID
  auto_create_network = false
}
// Enable API's
resource "google_project_service" "branchAPI" {
    project = google_project.branchProject.id
    service = "compute.googleapis.com"
}
// Create the VPC
resource "google_compute_network" "branchVPC" {
  project                 = google_project.branchProject.number
  name                    = "branch"
  auto_create_subnetworks = false
  routing_mode            = "GLOBAL"
  depends_on = [ google_project_service.branchAPI ]
}
// Create a FW rule to allow SSH via IAP to the test workstation
resource "google_compute_firewall" "ssh-branch" {
  name    = "ssh-branch"
  project = google_project.branchProject.number
  network = google_compute_network.branchVPC.name
  source_ranges = [ "35.235.240.0/20" ]
  allow {
    protocol = "tcp"
    ports = [ "22" ]
  }
}
// Create a subnet to host the test workstation
resource "google_compute_subnetwork" "branchUserSubnet" {
  name          = "branch-user"
  ip_cidr_range = var.branchUserSubnet
  region        = var.region
  project       = google_project.branchProject.number
  network       = google_compute_network.branchVPC.self_link
}
// Create a VPN gateway
resource "google_compute_ha_vpn_gateway" "branchGateway" {
  project = google_project.branchProject.number
  region  = var.region
  name    = "branch-gateway"
  network = google_compute_network.branchVPC.self_link
}
// Create a Cloud Router
resource "google_compute_router" "branchRouter" {
  project = google_project.branchProject.number
  region  = var.region
  name    = "branch-router"
  network = google_compute_network.branchVPC.name
  bgp {
    asn = 64514
  }
}
// Establish tunnels to the Datacenter Project
resource "google_compute_vpn_tunnel" "branch-dc-tunnel1" {
  name                  = "branch-dc-tunnel1"
  project               = google_project.branchProject.number
  region                = var.region
  vpn_gateway           = google_compute_ha_vpn_gateway.branchGateway.self_link
  peer_gcp_gateway      = google_compute_ha_vpn_gateway.dataCenterGateway.self_link
  shared_secret         = var.sharedSecret
  router                = google_compute_router.branchRouter.self_link
  vpn_gateway_interface = 0
}
resource "google_compute_vpn_tunnel" "branch-dc-tunnel2" {
  name                  = "branch-dc-tunnel2"
  project               = google_project.branchProject.number
  region                = var.region
  vpn_gateway           = google_compute_ha_vpn_gateway.branchGateway.self_link
  peer_gcp_gateway      = google_compute_ha_vpn_gateway.dataCenterGateway.self_link
  shared_secret         = var.sharedSecret
  router                = google_compute_router.branchRouter.self_link
  vpn_gateway_interface = 1
}
// Enable BGP peering to exchange routes between the branch and datacenter
resource "google_compute_router_interface" "branchRouterInterface1" {
  name       = "branch-router-interface1"
  project    =  google_project.branchProject.number
  router     = google_compute_router.branchRouter.name
  region     = var.region
  ip_range   = "169.254.0.1/30"
  vpn_tunnel = google_compute_vpn_tunnel.branch-dc-tunnel1.name
}
resource "google_compute_router_peer" "branchRouterPeer1" {
  name                      = "branch-router-peer1"
  project                   = google_project.branchProject.number
  router                    = google_compute_router.branchRouter.name
  region                    = var.region
  peer_ip_address           = "169.254.0.2"
  peer_asn                  = 64515
  advertised_route_priority = 100
  interface                 = google_compute_router_interface.branchRouterInterface1.name
}
resource "google_compute_router_interface" "branchRouterInterface2" {
  name       = "branch-router-interface2"
  project    = google_project.branchProject.number
  router     = google_compute_router.branchRouter.name
  region     = var.region
  ip_range   = "169.254.1.2/30"
  vpn_tunnel = google_compute_vpn_tunnel.branch-dc-tunnel2.name
}
resource "google_compute_router_peer" "branchRouterPeer2" {
  name                      = "branch-router-peer2"
  project                   = google_project.branchProject.number
  router                    = google_compute_router.branchRouter.name
  region                    = var.region
  peer_ip_address           = "169.254.1.1"
  peer_asn                  = 64515
  advertised_route_priority = 100
  interface                 = google_compute_router_interface.branchRouterInterface2.name
}
// Create a workstation to test our environment from a remote location
resource "google_compute_instance" "default" {
  name         = "branch-workstation"
  machine_type = "f1-micro"
  project      = google_project.branchProject.number
  zone         = "${var.region}-a"
  allow_stopping_for_update = true 

   lifecycle {
    ignore_changes = [metadata["ssh-keys"]]
  }
  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-11"
    }
  }
  metadata_startup_script = <<SCRIPT
    apt-get update
    apt-get upgrade -y
    SCRIPT
  network_interface {
    subnetwork = google_compute_subnetwork.branchUserSubnet.self_link
    access_config {
    }
  }
}
