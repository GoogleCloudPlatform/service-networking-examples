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
// Setup the DataCenter project that enables routing
// to be established between remote sites and the cloud
resource "google_project" "dataCenterProject" {
  name       = var.dataCenterProjectName
  project_id = "${var.dataCenterProjectName}-${random_id.randomProjectSuffix.dec}"
  folder_id = google_folder.disconnected.name
  billing_account = var.billingID
  auto_create_network = false
}
// Enable API's
resource "google_project_service" "dataCenterAPI" {
    project = google_project.dataCenterProject.id
    service = "compute.googleapis.com"
}
// Create the VPC
resource "google_compute_network" "dataCenterVPC" {
  project                 = google_project.dataCenterProject.number
  name                    = "datacenter"
  auto_create_subnetworks = false
  routing_mode            = "GLOBAL"
  depends_on = [ google_project_service.dataCenterAPI ]
}
// Create a subnet
resource "google_compute_subnetwork" "dataCenterComputeSubnet" {
  name          = "datacenter-compute"
  ip_cidr_range = var.dataCenterComputeSubnet
  region        = var.region
  project       = google_project.dataCenterProject.number
  network       = google_compute_network.dataCenterVPC.self_link
}
// Create the VPN gateway to peer to the remote branch
resource "google_compute_ha_vpn_gateway" "dataCenterGateway" {
  project = google_project.dataCenterProject.number
  region  = var.region
  name    = "datacenter-gateway"
  network = google_compute_network.dataCenterVPC.self_link
}
// Create the VPN gateway to peer to the Connectivity project
resource "google_compute_ha_vpn_gateway" "dataConnectivityGateway" {
  project = google_project.dataCenterProject.number
  region  = var.region
  name    = "data-connectivity-gateway"
  network = google_compute_network.dataCenterVPC.self_link
}
// Create a Cloud Router
resource "google_compute_router" "datacenterRouter" {
  project = google_project.dataCenterProject.number
  region  = var.region
  name    = "datacenter-router"
  network = google_compute_network.dataCenterVPC.name
  bgp {
    asn = 64515
    advertise_mode = "CUSTOM"
    advertised_groups = ["ALL_SUBNETS"]
    advertised_ip_ranges {
      range = "10.10.0.0/22"
    }
    advertised_ip_ranges {
      range = "10.30.0.0/22"
    }
  }
}
// Setup the tunnels to the Branch project
resource "google_compute_vpn_tunnel" "branch-dc-tunnel3" {
  name                  = "branch-dc-tunnel3"
  project               = google_project.dataCenterProject.number
  region                = var.region
  vpn_gateway           = google_compute_ha_vpn_gateway.dataCenterGateway.self_link
  peer_gcp_gateway      = google_compute_ha_vpn_gateway.branchGateway.self_link
  shared_secret         = var.sharedSecret
  router                = google_compute_router.datacenterRouter.self_link
  vpn_gateway_interface = 0
}

resource "google_compute_vpn_tunnel" "branch-dc-tunnel4" {
  name                  = "branch-dc-tunnel4"
  project               = google_project.dataCenterProject.number
  region                = var.region
  vpn_gateway           = google_compute_ha_vpn_gateway.dataCenterGateway.self_link
  peer_gcp_gateway      = google_compute_ha_vpn_gateway.branchGateway.self_link
  shared_secret         = var.sharedSecret
  router                = google_compute_router.datacenterRouter.self_link
  vpn_gateway_interface = 1
}
// Setup the tunnels to the Connectivity project
 resource "google_compute_vpn_tunnel" "dc-connectivity-tunnel1" {
  name                  = "dc-connectivity-tunnel1"
  project               = google_project.dataCenterProject.number
  region                = var.region
  vpn_gateway           = google_compute_ha_vpn_gateway.dataConnectivityGateway.self_link
  peer_gcp_gateway      = google_compute_ha_vpn_gateway.connectivityGateway.self_link
  shared_secret         = var.sharedSecret
  router                = google_compute_router.datacenterRouter.self_link
  vpn_gateway_interface = 0
}
resource "google_compute_vpn_tunnel" "dc-connectivity-tunnel2" {
  name                  = "dc-connectivity-tunnel2"
  project               = google_project.dataCenterProject.number
  region                = var.region
  vpn_gateway           = google_compute_ha_vpn_gateway.dataConnectivityGateway.self_link
  peer_gcp_gateway      = google_compute_ha_vpn_gateway.connectivityGateway.self_link
  shared_secret         = var.sharedSecret
  router                = google_compute_router.datacenterRouter.self_link
  vpn_gateway_interface = 1
}
// Establish BGP peering to the Branch project
resource "google_compute_router_interface" "datacenterRouterInterface1" {
  name       = "datacenter-router-interface1"
  project    = google_project.dataCenterProject.number
  router     = google_compute_router.datacenterRouter.name
  region     = var.region
  ip_range   = "169.254.0.2/30"
  vpn_tunnel = google_compute_vpn_tunnel.branch-dc-tunnel3.name
}
resource "google_compute_router_peer" "datacenterPeer1" {
  name                      = "datacenter-peer1"
  project                   = google_project.dataCenterProject.number
  router                    = google_compute_router.datacenterRouter.name
  region                    = var.region
  peer_ip_address           = "169.254.0.1"
  peer_asn                  = 64514
  advertised_route_priority = 100
  interface                 = google_compute_router_interface.datacenterRouterInterface1.name
}
resource "google_compute_router_interface" "datacenterRouterInterface2" {
  name       = "datacenter-router-interface2"
  project    = google_project.dataCenterProject.number
  router     = google_compute_router.datacenterRouter.name
  region     = var.region
  ip_range   = "169.254.1.1/30"
  vpn_tunnel = google_compute_vpn_tunnel.branch-dc-tunnel4.name
}
resource "google_compute_router_peer" "datacenterPeer2" {
  name                      = "datacenter-peer2"
  project                   = google_project.dataCenterProject.number
  router                    = google_compute_router.datacenterRouter.name
  region                    = var.region
  peer_ip_address           = "169.254.1.2"
  peer_asn                  = 64514
  advertised_route_priority = 100
  interface                 = google_compute_router_interface.datacenterRouterInterface2.name
}
// Establish BGP pering to the Connectivity project
resource "google_compute_router_interface" "datacenterRouterInterface3" {
  name       = "datacenter-router-interface3"
  project    = google_project.dataCenterProject.number
  router     = google_compute_router.datacenterRouter.name
  region     = var.region
  ip_range   = "169.254.3.1/30"
  vpn_tunnel = google_compute_vpn_tunnel.dc-connectivity-tunnel1.name
}

resource "google_compute_router_peer" "datacenterPeer3" {
  name                      = "datacenter-peer3"
  project                   = google_project.dataCenterProject.number
  router                    = google_compute_router.datacenterRouter.name
  region                    = var.region
  peer_ip_address           = "169.254.3.2"
  peer_asn                  = 64516
  advertised_route_priority = 100
  interface                 = google_compute_router_interface.datacenterRouterInterface3.name
}

resource "google_compute_router_interface" "datacenterRouterInterface4" {
  name       = "datacenter-router-interface4"
  project    = google_project.dataCenterProject.number
  router     = google_compute_router.datacenterRouter.name
  region     = var.region
  ip_range   = "169.254.4.2/30"
  vpn_tunnel = google_compute_vpn_tunnel.dc-connectivity-tunnel2.name
}

resource "google_compute_router_peer" "datacenterPeer4" {
  name                      = "datacenter-peer4"
  project                   = google_project.dataCenterProject.number
  router                    = google_compute_router.datacenterRouter.name
  region                    = var.region
  peer_ip_address           = "169.254.4.1"
  peer_asn                  = 64516
  advertised_route_priority = 100
  interface                 = google_compute_router_interface.datacenterRouterInterface4.name
}