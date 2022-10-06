terraform {
  required_version = "~> 1.1"

  required_providers {
    random = {
      version = "~> 3.4.3"
    }
    azurerm = {
      version = "~> 3.25.0"
    }
    http = {
      version = "~> 3.1.0"
    }
  }
}
