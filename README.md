# Macrina

Saint Macrina, patron of Robotics, ora pro nobis
---
UNDER CONSTRUCTION! It's still a rough draft that I'm ripping to shreds constantly. LMK if you'd like this to change
* CoAP binary request encoding and decoding (RFC 7253.3)
* CoAP Block Transfers (RFC 7959)
* Endpoint 
  * can receive and decode messages
  * started with arbitrary `handler` function for processing messages

## Overview

### `Macrina.Endpoint`
A thin `GenServer` wrapper around `:gen_udp`. Given an IP and port, any incoming UDP packets at that port will be sent to the `Endpoint`. This is done via `GenServer`'s built-in `handle_info` functionality.

### `Macrina.Connection.Server`
A `GenServer` that represents a connection from the local `Endpoint` that started it to some other `Endpoint`. Given an IP, port, and `Handler` module, this process serves two important functions: 
* general message handling
  * receiving `{:coap, binary()}` messages
  * decoding those messages
  * using the given `Handler` module to process the message and generate any CoAP responses
  * sending those responses via `:gen_udp`
* client message handling
  * the included `Macrina.Client` uses this process to send requests
  * clients use a `GenServer.call` to do this, which returns the response from the requested endpoint or times out

### `Macrina.Message`
Used for encoding and decoding `CoAP` messages, defining a `struct` for in memory representation
