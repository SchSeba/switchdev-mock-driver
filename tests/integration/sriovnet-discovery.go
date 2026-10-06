// SPDX-License-Identifier: GPL-2.0-only
// Build in the pinned ovs-cni checkout, using its vendored sriovnet dependency.
package main

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/k8snetworkplumbingwg/sriovnet"
	"github.com/vishvananda/netlink"
)

func main() {
	if len(os.Args) < 2 {
		panic("provide explicitly discovered VF PCI BDFs")
	}
	for _, pci := range os.Args[1:] {
		uplink, err := sriovnet.GetUplinkRepresentor(pci)
		if err != nil {
			panic(err)
		}
		index, err := sriovnet.GetVfIndexByPciAddress(pci)
		if err != nil {
			panic(err)
		}
		link, err := netlink.LinkByName(uplink)
		if err != nil {
			panic(err)
		}
		if index < 0 || index >= len(link.Attrs().Vfs) || link.Attrs().Vfs[index].ID != index {
			panic("default netlink lookup must return the actual PF VF information")
		}
		rep, err := sriovnet.GetVfRepresentor(uplink, index)
		if err != nil {
			panic(err)
		}
		endpoints, err := sriovnet.GetNetDevicesFromPci(pci)
		if err != nil {
			panic(err)
		}
		result := struct {
			PCI           string   `json:"pci"`
			Uplink        string   `json:"uplink"`
			VF            int      `json:"vf"`
			Representor   string   `json:"representor"`
			HostEndpoints []string `json:"host_endpoints"`
		}{pci, uplink, index, rep, endpoints}
		data, err := json.Marshal(result)
		if err != nil {
			panic(err)
		}
		fmt.Println(string(data))
	}
}
