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
// Setup the Connectivity project that hosts the service
// attachements that clients consume
resource "google_project" "connectivityProject" {
  name       = var.connectivityProjectName
  project_id = "${var.connectivityProjectName}-${random_id.randomProjectSuffix.dec}"
  folder_id = google_folder.disconnected.name
  billing_account = var.billingID
  auto_create_network = false
}
// Enable API's
resource "google_project_service" "connectivityAPI" {
    project = google_project.connectivityProject.id
    service = "compute.googleapis.com"
}
// Create the VPC
resource "google_compute_network" "connectivityVPC" {
  project                 = google_project.connectivityProject.number
  name                    = "connectivity"
  auto_create_subnetworks = false
  routing_mode            = "GLOBAL"
  depends_on = [ google_project_service.connectivityAPI ]
}
// Create a subnet to host the service attachments
resource "google_compute_subnetwork" "connectivityComputeSubnet" {
  name          = "connectivity-compute"
  ip_cidr_range = var.connectivityComputeSubnet
  region        = var.region
  project       = google_project.connectivityProject.number
  network       = google_compute_network.connectivityVPC.self_link
}
// Create a VPN Gateway
resource "google_compute_ha_vpn_gateway" "connectivityGateway" {
  project = google_project.connectivityProject.number
  region  = var.region
  name    = "connectivity-gateway"
  network = google_compute_network.connectivityVPC.self_link
}
// Create a Cloud Router
resource "google_compute_router" "connectivityRouter" {
  project = google_project.connectivityProject.number
  region  = var.region
  name    = "connectivity-router"
  network = google_compute_network.connectivityVPC.name
  bgp {
    asn = 64516
  }
}
// Establish tunnels to the Datacenter project
resource "google_compute_vpn_tunnel" "dc-connectivity-tunnel3" {
  name                  = "dc-connectivity-tunnel3"
  project               = google_project.connectivityProject.number
  region                = var.region
  vpn_gateway           = google_compute_ha_vpn_gateway.connectivityGateway.self_link
  peer_gcp_gateway      = google_compute_ha_vpn_gateway.dataConnectivityGateway.self_link
  shared_secret         = var.sharedSecret
  router                = google_compute_router.connectivityRouter.self_link
  vpn_gateway_interface = 0
}
resource "google_compute_vpn_tunnel" "dc-connectivity-tunnel4" {
  name                  = "dc-connectivity-tunnel4"
  project               = google_project.connectivityProject.number
  region                = var.region
  vpn_gateway           = google_compute_ha_vpn_gateway.connectivityGateway.self_link
  peer_gcp_gateway      = google_compute_ha_vpn_gateway.dataConnectivityGateway.self_link
  shared_secret         = var.sharedSecret
  router                = google_compute_router.connectivityRouter.self_link
  vpn_gateway_interface = 1
}
// Establish BGP peering to exchange routes with the Datacenter
resource "google_compute_router_interface" "connectivityRouterInterface1" {
  name       = "connectivity-router-interface1"
  project    = google_project.connectivityProject.number
  router     = google_compute_router.connectivityRouter.name
  region     = var.region
  ip_range   = "169.254.3.2/30"
  vpn_tunnel = google_compute_vpn_tunnel.dc-connectivity-tunnel3.name
}
resource "google_compute_router_peer" "connectivityPeer1" {
  name                      = "connectivity-peer1"
  project                   = google_project.connectivityProject.number
  router                    = google_compute_router.connectivityRouter.name
  region                    = var.region
  peer_ip_address           = "169.254.3.1"
  peer_asn                  = 64515
  advertised_route_priority = 100
  interface                 = google_compute_router_interface.connectivityRouterInterface1.name
}
resource "google_compute_router_interface" "connectivityRouterInterface2" {
  name       = "connectivity-router-interface2"
  project    = google_project.connectivityProject.number
  router     = google_compute_router.connectivityRouter.name
  region     = var.region
  ip_range   = "169.254.4.1/30"
  vpn_tunnel = google_compute_vpn_tunnel.dc-connectivity-tunnel4.name
}
resource "google_compute_router_peer" "connectivityPeer2" {
  name                      = "connectivity-peer2"
  project                   = google_project.connectivityProject.number
  router                    = google_compute_router.connectivityRouter.name
  region                    = var.region
  peer_ip_address           = "169.254.4.2"
  peer_asn                  = 64515
  advertised_route_priority = 100
  interface                 = google_compute_router_interface.connectivityRouterInterface2.name
}
// Reserve an VPC internal IP address to use as a Service Attachment
resource "google_compute_address" "app1_consumer" {
  name         = "app1-consumer"
  project      = google_project.connectivityProject.number
  subnetwork   = google_compute_subnetwork.connectivityComputeSubnet.self_link
  address_type = "INTERNAL"
  address      = var.app1-consumer-ip
  region       = var.region
}
// Create the Service Attachement for App1 that clients will target
resource "google_compute_forwarding_rule" "app1_consumer_rule" {
  name                  = "app1-consumer-forwarding-rule"
  project               = google_project.connectivityProject.number
  region                = var.region
  target                = google_compute_service_attachment.app1_service_attachment.self_link
  load_balancing_scheme = ""
  ip_address            = google_compute_address.app1_consumer.self_link
  network               = google_compute_network.connectivityVPC.name
}
