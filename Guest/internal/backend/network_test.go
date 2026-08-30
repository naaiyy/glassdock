package backend

import (
	"errors"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"

	"github.com/glassdock/glassdock/guest/internal/api"
)

var errRequested = errors.New("requested failure")

type recordingNetworkRunner struct {
	commands []string
	failOn   string
}

func (r *recordingNetworkRunner) Run(name string, args ...string) error {
	command := strings.Join(append([]string{name}, args...), " ")
	r.commands = append(r.commands, command)
	if r.failOn != "" && strings.Contains(command, r.failOn) {
		return errRequested
	}
	return nil
}

type recordingNetworkNamespaces struct{ runner *recordingNetworkRunner }

func (n recordingNetworkNamespaces) Create(name, hostVeth, containerVeth, address string) error {
	return n.runner.Run("netlink", "create", name, hostVeth, containerVeth, "addr", address+"/16", "dev", "eth0", "route", "default", "via", "10.88.0.1")
}

func (n recordingNetworkNamespaces) Delete(name string) error {
	return n.runner.Run("netlink", "delete", name)
}

type recordingNativeNetworkNamespaces struct{ runner *recordingNetworkRunner }

func (n recordingNativeNetworkNamespaces) Create(name, hostVeth, containerVeth, address string) error {
	return recordingNetworkNamespaces{runner: n.runner}.Create(name, hostVeth, containerVeth, address)
}

func (n recordingNativeNetworkNamespaces) Delete(name string) error {
	return recordingNetworkNamespaces{runner: n.runner}.Delete(name)
}

func (n recordingNativeNetworkNamespaces) Attach(
	namespace, bridge, hostVeth, containerVeth string,
	ipv4Address string, ipv4Prefix int,
	ipv6Address string, ipv6Prefix int,
	ipv4Gateway string, ipv6Gateway string,
	interfaceName string,
) error {
	return n.runner.Run(
		"native-attach", namespace, bridge, hostVeth, containerVeth,
		ipv4Address, strconv.Itoa(ipv4Prefix), ipv6Address, strconv.Itoa(ipv6Prefix),
		ipv4Gateway, ipv6Gateway, interfaceName,
	)
}

func (n recordingNativeNetworkNamespaces) Detach(namespace, interfaceName string) error {
	return n.runner.Run("native-detach", namespace, interfaceName)
}

func newTestNetworkManager(runner *recordingNetworkRunner) *NetworkManager {
	return newNetworkManager(runner, recordingNetworkNamespaces{runner: runner})
}

func TestNetworkManagerCreatesConfiguredNamespace(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	path, err := manager.Create("container-one")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(path, "/run/netns/st") {
		t.Fatalf("unexpected namespace path %q", path)
	}
	joined := strings.Join(runner.commands, "\n")
	for _, expected := range []string{
		"ip link add glassdock0 type bridge",
		"sysctl -w net.ipv4.ip_forward=1",
		"iptables -t nat -A POSTROUTING -s 10.88.0.0/16",
		"addr 10.88.0.2/16 dev eth0",
		"route default via 10.88.0.1",
	} {
		if !strings.Contains(joined, expected) {
			t.Fatalf("commands do not contain %q:\n%s", expected, joined)
		}
	}
}

func TestNetworkManagerUsesUniqueIngressPortsForSameContainerPort(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	for _, id := range []string{"first", "second"} {
		if _, err := manager.Create(id); err != nil {
			t.Fatal(err)
		}
	}
	request := []api.PublishedPort{{ContainerPort: 80, Protocol: "tcp"}}
	first, err := manager.Publish("first", request)
	if err != nil {
		t.Fatal(err)
	}
	second, err := manager.Publish("second", request)
	if err != nil {
		t.Fatal(err)
	}
	if first[0].GuestPort == second[0].GuestPort {
		t.Fatalf("ingress ports collided: %d", first[0].GuestPort)
	}
	if first[0].ContainerPort != 80 || second[0].ContainerPort != 80 {
		t.Fatalf("container ports changed: %#v %#v", first, second)
	}
	before := len(runner.commands)
	repeated, err := manager.Publish("first", request)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(first, repeated) || len(runner.commands) != before {
		t.Fatal("repeat publication was not idempotent")
	}
}

func TestNetworkManagerReportsPreparedPublication(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	if _, err := manager.Create("web"); err != nil {
		t.Fatal(err)
	}
	want := []api.PublishedPort{{ContainerPort: 80, GuestPort: 42000, Protocol: "tcp"}}
	if _, err := manager.Publish("web", want); err != nil {
		t.Fatal(err)
	}
	got := manager.Published("web")
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("published ports = %#v, want %#v", got, want)
	}
	got[0].GuestPort = 1
	if manager.Published("web")[0].GuestPort != 42000 {
		t.Fatal("Published returned mutable internal storage")
	}
}

func TestNetworkManagerReportsSortedContainerEndpoints(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	for _, id := range []string{"container-b", "container-a"} {
		if _, err := manager.Create(id); err != nil {
			t.Fatal(err)
		}
	}

	endpoints := manager.Endpoints()
	if len(endpoints) != 2 {
		t.Fatalf("endpoint count = %d, want 2", len(endpoints))
	}
	if endpoints[0].ContainerID != "container-a" || endpoints[1].ContainerID != "container-b" {
		t.Fatalf("endpoints are not sorted: %#v", endpoints)
	}
	if endpoints[0].Address != "10.88.0.3" || endpoints[1].Address != "10.88.0.2" || endpoints[0].EndpointID == "" {
		t.Fatalf("endpoint metadata = %#v", endpoints[0])
	}
}

func TestNetworkManagerPreservesIPAMRangeAuxiliaryAndIPv6State(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	resource, err := manager.CreateNetwork(api.NetworkCreateRequest{
		Name:       "frontend",
		EnableIPv6: true,
		IPAM: &api.NetworkIPAM{Driver: "default", Config: []api.NetworkIPAMConfig{{
			Subnet: "10.120.0.0/16", IPRange: "10.120.10.0/24", Gateway: "10.120.0.1",
			AuxiliaryAddresses: map[string]string{"router": "10.120.0.2"},
		}}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !resource.EnableIPv6 || len(resource.IPAM.Config) != 2 {
		t.Fatalf("network capabilities = %#v", resource)
	}
	config := resource.IPAM.Config[0]
	if config.IPRange != "10.120.10.0/24" || config.AuxiliaryAddresses["router"] != "10.120.0.2" {
		t.Fatalf("IPAM config = %#v", config)
	}
	if resource.IPAM.Config[1].Subnet != "fd00:1::/64" || resource.IPAM.Config[1].Gateway != "fd00:1::1" {
		t.Fatalf("IPv6 IPAM config = %#v", resource.IPAM.Config[1])
	}
	if _, err := manager.Create("container-one"); err != nil {
		t.Fatal(err)
	}
	resource, err = manager.ConnectNetwork(api.NetworkConnectRequest{
		NetworkID: resource.ID, ContainerID: "container-one",
		IPv4Address: "10.120.10.25", IPv6Address: "fd00:1::25",
	})
	if err != nil {
		t.Fatal(err)
	}
	endpoint := resource.Containers["container-one"]
	if endpoint.IPv4Address != "10.120.10.25" || endpoint.IPv6Address != "fd00:1::25" {
		t.Fatalf("endpoint = %#v", endpoint)
	}
}

func TestNetworkManagerInstallsTCPKernelForwardingRules(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	if _, err := manager.Create("web"); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Publish("web", []api.PublishedPort{{
		ContainerPort: 8080, GuestPort: 42000, Protocol: "tcp",
	}}); err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(runner.commands, "\n")
	for _, expected := range []string{
		"iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 42000",
		"-j DNAT --to-destination 10.88.0.2:8080",
		"iptables -A FORWARD -i eth0 -o glassdock0 -p tcp -d 10.88.0.2 --dport 8080",
		"iptables -A FORWARD -i glassdock0 -o eth0 -p tcp -s 10.88.0.2 --sport 8080",
		"--comment glassdock:st",
	} {
		if !strings.Contains(joined, expected) {
			t.Fatalf("kernel rules do not contain %q:\n%s", expected, joined)
		}
	}
}

func TestNetworkManagerInstallsAndRemovesExactUDPRules(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	if _, err := manager.Create("dns"); err != nil {
		t.Fatal(err)
	}
	published, err := manager.Publish("dns", []api.PublishedPort{{ContainerPort: 53, Protocol: "udp"}})
	if err != nil {
		t.Fatal(err)
	}
	if err := manager.Delete("dns"); err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(runner.commands, "\n")
	guestPort := strconv.Itoa(int(published[0].GuestPort))
	for _, expected := range []string{
		"iptables -t nat -A PREROUTING -i eth0 -p udp --dport " + guestPort,
		"iptables -t nat -D PREROUTING -i eth0 -p udp --dport " + guestPort,
		"iptables -D FORWARD -i eth0 -o glassdock0 -p udp",
		"iptables -D FORWARD -i glassdock0 -o eth0 -p udp",
	} {
		if !strings.Contains(joined, expected) {
			t.Fatalf("UDP lifecycle does not contain %q:\n%s", expected, joined)
		}
	}
}

func TestNetworkManagerPreservesHostSourceMetadataWithKernelIngress(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	if _, err := manager.Create("web"); err != nil {
		t.Fatal(err)
	}
	requested := []api.PublishedPort{{
		ContainerPort: 80, GuestPort: 42000, Protocol: "tcp", HostSource: "192.168.64.1",
	}}
	published, err := manager.Publish("web", requested)
	if err != nil {
		t.Fatal(err)
	}
	if published[0].HostSource != "192.168.64.1" {
		t.Fatalf("host source = %q", published[0].HostSource)
	}
	joined := strings.Join(runner.commands, "\n")
	if !strings.Contains(joined, "PREROUTING -i eth0 -p tcp --dport 42000") {
		t.Fatalf("kernel ingress rule is absent:\n%s", joined)
	}
}

func TestDeferredNetworkPreparationCreatesAndPublishesAtomically(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	backend := &Backend{network: manager}
	want := []api.PublishedPort{{ContainerPort: 80, GuestPort: 42000, Protocol: "tcp"}}
	if _, err := backend.prepareNetwork("web", want); err != nil {
		t.Fatal(err)
	}
	if got := manager.Published("web"); !reflect.DeepEqual(got, want) {
		t.Fatalf("published ports = %#v, want %#v", got, want)
	}
}

func TestDeferredNetworkPreparationRollsBackInvalidPublication(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	backend := &Backend{network: manager}
	_, err := backend.prepareNetwork("web", []api.PublishedPort{{ContainerPort: 0, Protocol: "tcp"}})
	if err == nil {
		t.Fatal("invalid publication succeeded")
	}
	if _, err := manager.Publish("web", []api.PublishedPort{{ContainerPort: 80}}); err == nil {
		t.Fatal("failed deferred preparation left its network behind")
	}
}

func TestNetworkManagerReusesKnownNamespaceWithoutAProcess(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	first, err := manager.Create("reused")
	if err != nil {
		t.Fatal(err)
	}
	commandCount := len(runner.commands)
	second, err := manager.Create("reused")
	if err != nil {
		t.Fatal(err)
	}
	if first != second {
		t.Fatalf("namespace path changed: %q != %q", first, second)
	}
	if len(runner.commands) != commandCount {
		t.Fatalf("known namespace executed another command: %#v", runner.commands[commandCount:])
	}
}

func TestNetworkManagerDeleteRemovesPublicationAndNamespace(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	if _, err := manager.Create("web"); err != nil {
		t.Fatal(err)
	}
	_, err := manager.Publish("web", []api.PublishedPort{{ContainerPort: 8080, Protocol: "tcp"}})
	if err != nil {
		t.Fatal(err)
	}
	if err := manager.Delete("web"); err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(runner.commands, "\n")
	if !strings.Contains(joined, "netlink delete st") {
		t.Fatalf("namespace delete is absent:\n%s", joined)
	}
}

func TestNetworkManagerRejectsDuplicateGuestPortAcrossContainers(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	for _, id := range []string{"first", "second"} {
		if _, err := manager.Create(id); err != nil {
			t.Fatal(err)
		}
	}
	port := []api.PublishedPort{{ContainerPort: 80, GuestPort: 42000, Protocol: "tcp"}}
	if _, err := manager.Publish("first", port); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Publish("second", port); err == nil || !strings.Contains(err.Error(), "already owned") {
		t.Fatalf("duplicate publication error = %v", err)
	}
}

func TestNetworkManagerRejectsDuplicateGuestPortInOneRequest(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	if _, err := manager.Create("web"); err != nil {
		t.Fatal(err)
	}
	_, err := manager.Publish("web", []api.PublishedPort{
		{ContainerPort: 80, GuestPort: 42000, Protocol: "tcp"},
		{ContainerPort: 81, GuestPort: 42000, Protocol: "tcp"},
	})
	if err == nil || !strings.Contains(err.Error(), "duplicated") {
		t.Fatalf("duplicate request error = %v", err)
	}
	joined := strings.Join(runner.commands, "\n")
	if !strings.Contains(joined, "iptables -t nat -D PREROUTING") {
		t.Fatalf("duplicate request did not roll back its first rule set:\n%s", joined)
	}
}

func TestNetworkManagerAllowsTCPAndUDPOnSameGuestPort(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	if _, err := manager.Create("dual"); err != nil {
		t.Fatal(err)
	}
	published, err := manager.Publish("dual", []api.PublishedPort{
		{ContainerPort: 80, GuestPort: 42000, Protocol: "TCP"},
		{ContainerPort: 53, GuestPort: 42000, Protocol: "udp"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if published[0].Protocol != "tcp" || published[1].Protocol != "udp" {
		t.Fatalf("protocols were not normalized: %#v", published)
	}
	joined := strings.Join(runner.commands, "\n")
	if !strings.Contains(joined, "-p tcp --dport 42000") ||
		!strings.Contains(joined, "-p udp --dport 42000") {
		t.Fatalf("dual-protocol rules are incomplete:\n%s", joined)
	}
}

func TestNetworkManagerRollsBackPartialRuleInstallation(t *testing.T) {
	runner := &recordingNetworkRunner{failOn: "-A FORWARD -i eth0"}
	manager := newTestNetworkManager(runner)
	if _, err := manager.Create("web"); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Publish("web", []api.PublishedPort{{ContainerPort: 80, GuestPort: 42000, Protocol: "tcp"}}); !errors.Is(err, errRequested) {
		t.Fatalf("publish error = %v", err)
	}
	joined := strings.Join(runner.commands, "\n")
	if !strings.Contains(joined, "iptables -t nat -D PREROUTING") {
		t.Fatalf("partial DNAT rule was not rolled back:\n%s", joined)
	}
	if got := manager.Published("web"); len(got) != 0 {
		t.Fatalf("failed publication became visible: %#v", got)
	}
}

func TestNetworkManagerRejectsChangedRepublish(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	if _, err := manager.Create("web"); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Publish("web", []api.PublishedPort{{ContainerPort: 80, GuestPort: 42000}}); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Publish("web", []api.PublishedPort{{ContainerPort: 81, GuestPort: 42000}}); err == nil {
		t.Fatal("changed publication was treated as idempotent")
	}
}

func TestNetworkManagerCreatesAndMutatesGuestNetworkObjects(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	request := api.NetworkCreateRequest{
		Name:   "frontend",
		Driver: "bridge",
		IPAM:   &api.NetworkIPAM{Config: []api.NetworkIPAMConfig{{Subnet: "10.89.0.0/16", Gateway: "10.89.0.1"}}},
		Labels: map[string]string{"tier": "web"},
	}
	created, err := manager.CreateNetwork(request)
	if err != nil {
		t.Fatal(err)
	}
	if created.Name != "frontend" || created.Driver != "bridge" || created.IPAM.Config[0].Subnet != "10.89.0.0/16" {
		t.Fatalf("created network = %#v", created)
	}
	if _, err := manager.Create("container-one"); err != nil {
		t.Fatal(err)
	}
	if err := manager.Connect(created.ID, "container-one", "web", "", "", false); err != nil {
		t.Fatal(err)
	}
	summaries := manager.Summaries(map[string]string{"container-one": "web"})
	var frontend api.NetworkSummary
	for _, summary := range summaries {
		if summary.ID == created.ID {
			frontend = summary
		}
	}
	endpoint, ok := frontend.Containers["container-one"]
	if !ok || endpoint.Name != "web" || endpoint.IPv4Address != "10.89.0.2/16" {
		t.Fatalf("frontend endpoint = %#v", endpoint)
	}
	if err := manager.Connect(created.ID, "container-one", "web", "", "", true); err == nil || !strings.Contains(err.Error(), "already connected") {
		t.Fatalf("duplicate running connect error = %v", err)
	}
	if err := manager.Disconnect(created.ID, "container-one", false); err != nil {
		t.Fatal(err)
	}
	for _, summary := range manager.Summaries(nil) {
		if summary.ID == created.ID && len(summary.Containers) != 0 {
			t.Fatalf("disconnected network still has endpoints: %#v", summary.Containers)
		}
	}
}

func TestNetworkManagerCreatesLogicalNetworkAndAttachesContainer(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	resource, err := manager.CreateNetwork(api.NetworkCreateRequest{
		Name: "frontend", Labels: map[string]string{"tier": "edge"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if resource.Name != "frontend" || resource.Driver != "bridge" || resource.Subnet == "" {
		t.Fatalf("unexpected network resource: %#v", resource)
	}
	if _, err := manager.Create("web"); err != nil {
		t.Fatal(err)
	}
	manager.SetContainerIdentity("web", "web", "web-host")
	connected, err := manager.ConnectNetwork(api.NetworkConnectRequest{
		NetworkID: resource.ID, ContainerID: "web", Aliases: []string{"api"},
	})
	if err != nil {
		t.Fatal(err)
	}
	endpoint := connected.Containers["web"]
	if endpoint.IPv4Address == "" || endpoint.Gateway == "" || !reflect.DeepEqual(endpoint.Aliases, []string{"web", "api"}) {
		t.Fatalf("unexpected attached endpoint: %#v", endpoint)
	}
	joined := strings.Join(runner.commands, "\n")
	for _, expected := range []string{
		"ip link add gd" + resource.ID[:10] + " type bridge",
		"netlink attach st",
	} {
		if !strings.Contains(joined, expected) {
			t.Fatalf("network commands do not contain %q:\n%s", expected, joined)
		}
	}
	hosts, nameservers, err := manager.HostsFile("web")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(hosts, endpoint.IPv4Address+" web\n") ||
		!strings.Contains(hosts, endpoint.IPv4Address+" api\n") ||
		!strings.Contains(hosts, endpoint.IPv4Address+" web-host\n") {
		t.Fatalf("managed hosts file omitted aliases:\n%s", hosts)
	}
	if len(nameservers) != 2 {
		t.Fatalf("nameservers = %#v, want default and custom gateways", nameservers)
	}
}

func TestNetworkManagerSupportsRequestedDualStackAddresses(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	resource, err := manager.CreateNetwork(api.NetworkCreateRequest{
		Name:       "dual-stack",
		EnableIPv6: true,
		IPAM: &api.NetworkIPAM{Config: []api.NetworkIPAMConfig{
			{Subnet: "10.121.0.0/24", Gateway: "10.121.0.1"},
			{Subnet: "fd00:121::/64", Gateway: "fd00:121::1"},
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(resource.IPAM.Config) != 2 || resource.IPAM.Config[1].Subnet != "fd00:121::/64" {
		t.Fatalf("dual-stack IPAM = %#v", resource.IPAM.Config)
	}
	if _, err := manager.Create("web"); err != nil {
		t.Fatal(err)
	}
	if err := manager.ConfigureContainerNetworkWithAddresses(
		"web", resource.Name, "web", "10.121.0.25", "fd00:121::25", []string{"api"},
	); err != nil {
		t.Fatal(err)
	}
	attached, err := manager.InspectNetwork(resource.ID)
	if err != nil {
		t.Fatal(err)
	}
	endpoint := attached.Containers["web"]
	if endpoint.IPv4Address != "10.121.0.25" || endpoint.IPv6Address != "fd00:121::25" {
		t.Fatalf("dual-stack endpoint = %#v", endpoint)
	}
	joined := strings.Join(runner.commands, "\n")
	for _, expected := range []string{
		"addr 10.121.0.25/24",
		"addr6 fd00:121::25/64",
		"route4 default via 10.121.0.1",
		"route6 default via fd00:121::1",
	} {
		if !strings.Contains(joined, expected) {
			t.Fatalf("dual-stack attach is missing %q:\n%s", expected, joined)
		}
	}
}

func TestNetworkManagerForwardsDualStackToNativeAttachmentOperations(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newNetworkManager(runner, recordingNativeNetworkNamespaces{runner: runner})
	resource, err := manager.CreateNetwork(api.NetworkCreateRequest{
		Name: "native-dual-stack", EnableIPv6: true,
		IPAM: &api.NetworkIPAM{Config: []api.NetworkIPAMConfig{
			{Subnet: "10.123.0.0/24", Gateway: "10.123.0.1"},
			{Subnet: "fd00:123::/64", Gateway: "fd00:123::1"},
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Create("web"); err != nil {
		t.Fatal(err)
	}
	if err := manager.ConfigureContainerNetworkWithAddresses(
		"web", resource.Name, "web", "10.123.0.25", "fd00:123::25", nil,
	); err != nil {
		t.Fatal(err)
	}

	joined := strings.Join(runner.commands, "\n")
	for _, expected := range []string{
		"native-attach",
		"10.123.0.25 24",
		"fd00:123::25 64",
		"10.123.0.1 fd00:123::1",
	} {
		if !strings.Contains(joined, expected) {
			t.Fatalf("native dual-stack attach is missing %q:\n%s", expected, joined)
		}
	}
}

func TestNetworkManagerSupportsIPv6OnlyNetworks(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	enableIPv4 := false
	resource, err := manager.CreateNetwork(api.NetworkCreateRequest{
		Name:       "ipv6-only",
		EnableIPv4: &enableIPv4,
		EnableIPv6: true,
		IPAM: &api.NetworkIPAM{Config: []api.NetworkIPAMConfig{{
			Subnet: "fd00:122::/64", Gateway: "fd00:122::1",
		}}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if resource.EnableIPv4 || !resource.EnableIPv6 || len(resource.IPAM.Config) != 1 {
		t.Fatalf("IPv6-only network = %#v", resource)
	}
	if _, err := manager.Create("v6-client"); err != nil {
		t.Fatal(err)
	}
	if err := manager.ConfigureContainerNetworkWithAddresses(
		"v6-client", resource.Name, "v6-client", "", "fd00:122::25", nil,
	); err != nil {
		t.Fatal(err)
	}
	attached, err := manager.InspectNetwork(resource.ID)
	if err != nil {
		t.Fatal(err)
	}
	endpoint := attached.Containers["v6-client"]
	if endpoint.IPv4Address != "" || endpoint.IPv6Address != "fd00:122::25" {
		t.Fatalf("IPv6-only endpoint = %#v", endpoint)
	}
	joined := strings.Join(runner.commands, "\n")
	if !strings.Contains(joined, "addr6 fd00:122::25/64") ||
		!strings.Contains(joined, "route6 default via fd00:122::1") {
		t.Fatalf("IPv6-only attach is incomplete:\n%s", joined)
	}
	if !strings.Contains(joined, "netlink attach st") {
		t.Fatalf("IPv6-only attach command is absent:\n%s", joined)
	}
}

func TestNetworkManagerReplacesDefaultEndpointForContainerNetworkMode(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	frontend, err := manager.CreateNetwork(api.NetworkCreateRequest{Name: "frontend"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Create("web"); err != nil {
		t.Fatal(err)
	}
	manager.SetContainerIdentity("web", "web", "")
	if err := manager.ConfigureContainerNetwork("web", "frontend", "web"); err != nil {
		t.Fatal(err)
	}

	bridge, err := manager.InspectNetwork("bridge")
	if err != nil {
		t.Fatal(err)
	}
	if len(bridge.Containers) != 0 {
		t.Fatalf("default bridge still contains the custom-network container: %#v", bridge.Containers)
	}
	connected, err := manager.InspectNetwork(frontend.ID)
	if err != nil {
		t.Fatal(err)
	}
	endpoint, ok := connected.Containers["web"]
	if !ok || endpoint.IPv4Address == "" {
		t.Fatalf("custom network endpoint = %#v", connected.Containers)
	}
	if got, ok := manager.PublishedTCPDestination(42000); ok || got != "" {
		t.Fatalf("unexpected publication before publish: %q, %v", got, ok)
	}
	if !strings.Contains(strings.Join(runner.commands, "\n"), "netlink detach st") {
		t.Fatalf("default endpoint was not detached: %#v", runner.commands)
	}
}

func TestNetworkManagerRestoresContainerNetworkAttachments(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	frontend, err := manager.CreateNetwork(api.NetworkCreateRequest{Name: "frontend"})
	if err != nil {
		t.Fatal(err)
	}
	created, err := manager.RestoreContainer(
		"web", "web", "web-host", "private",
		[]api.ContainerNetworkAttachment{{
			NetworkID: frontend.ID, IPv4Address: "10.89.0.25", Aliases: []string{"api"},
		}},
	)
	if err != nil {
		t.Fatal(err)
	}
	if !created {
		t.Fatal("RestoreContainer did not create the container namespace")
	}
	resource, err := manager.InspectNetwork(frontend.ID)
	if err != nil {
		t.Fatal(err)
	}
	endpoint, ok := resource.Containers["web"]
	if !ok || endpoint.IPv4Address != "10.89.0.25" || !reflect.DeepEqual(endpoint.Aliases, []string{"web", "api"}) {
		t.Fatalf("restored endpoint = %#v", endpoint)
	}
	bridge, err := manager.InspectNetwork("bridge")
	if err != nil {
		t.Fatal(err)
	}
	if len(bridge.Containers) != 1 {
		t.Fatalf("restored default endpoint count = %d, want 1", len(bridge.Containers))
	}
}

func TestNetworkManagerRestoresDisconnectedCustomNetworkWithoutImplicitEndpoint(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	frontend, err := manager.CreateNetwork(api.NetworkCreateRequest{Name: "frontend"})
	if err != nil {
		t.Fatal(err)
	}
	created, err := manager.RestoreContainer("web", "web", "", "frontend", nil)
	if err != nil {
		t.Fatal(err)
	}
	if !created {
		t.Fatal("RestoreContainer did not create the container namespace")
	}
	custom, err := manager.InspectNetwork(frontend.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(custom.Containers) != 0 {
		t.Fatalf("disconnected custom network was implicitly restored: %#v", custom.Containers)
	}
	bridge, err := manager.InspectNetwork("bridge")
	if err != nil {
		t.Fatal(err)
	}
	if len(bridge.Containers) != 0 {
		t.Fatalf("implicit default endpoint remained after custom disconnect: %#v", bridge.Containers)
	}
}

func TestNetworkManagerProtectsDefaultBridgeFromDisconnect(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	if _, err := manager.Create("web"); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.DisconnectNetwork(api.NetworkDisconnectRequest{
		NetworkID: "bridge", ContainerID: "web",
	}); err == nil || !strings.Contains(err.Error(), "default bridge") {
		t.Fatalf("default bridge disconnect error = %v", err)
	}
	bridge, err := manager.InspectNetwork("bridge")
	if err != nil {
		t.Fatal(err)
	}
	if len(bridge.Containers) != 1 {
		t.Fatalf("default bridge endpoint count = %d, want 1", len(bridge.Containers))
	}
}

func TestNetworkManagerPersistsAndRestoresCustomNetworks(t *testing.T) {
	statePath := filepath.Join(t.TempDir(), "networks.json")
	runner := &recordingNetworkRunner{}
	first := newTestNetworkManager(runner)
	first.statePath = statePath
	created, err := first.CreateNetwork(api.NetworkCreateRequest{
		Name: "persistent", Internal: true, Labels: map[string]string{"tier": "data"},
	})
	if err != nil {
		t.Fatal(err)
	}

	second := newTestNetworkManager(runner)
	second.statePath = statePath
	if err := second.Initialize(); err != nil {
		t.Fatal(err)
	}
	restored, err := second.InspectNetwork("persistent")
	if err != nil {
		t.Fatal(err)
	}
	if restored.ID != created.ID || restored.Name != created.Name ||
		restored.IPAM.Config[0].Subnet != created.IPAM.Config[0].Subnet ||
		restored.Labels["tier"] != "data" {
		t.Fatalf("restored network = %#v, created = %#v", restored, created)
	}
}

func TestNetworkManagerHotDisconnectAndPruneAreStateful(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	resource, err := manager.CreateNetwork(api.NetworkCreateRequest{Name: "temporary"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Create("web"); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.ConnectNetwork(api.NetworkConnectRequest{NetworkID: resource.ID, ContainerID: "web"}); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.DisconnectNetwork(api.NetworkDisconnectRequest{NetworkID: resource.ID, ContainerID: "web"}); err != nil {
		t.Fatal(err)
	}
	if inspected, err := manager.InspectNetwork(resource.ID); err != nil {
		t.Fatal(err)
	} else if len(inspected.Containers) != 0 {
		t.Fatalf("disconnected network still has endpoints: %#v", inspected.Containers)
	}
	pruned := manager.PruneNetworks(map[string][]string{"dangling": {"true"}})
	if !reflect.DeepEqual(pruned.NetworksDeleted, []string{resource.ID}) {
		t.Fatalf("pruned networks = %#v, want %q", pruned.NetworksDeleted, resource.ID)
	}
	if !strings.Contains(strings.Join(runner.commands, "\n"), "netlink detach st") {
		t.Fatalf("hot disconnect did not remove the namespace interface: %#v", runner.commands)
	}
}
