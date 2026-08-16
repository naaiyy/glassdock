package backend

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"net"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/glassdock/glassdock/guest/internal/api"
)

const (
	bridgeName  = "glassdock0"
	bridgeCIDR  = "10.88.0.1/16"
	networkCIDR = "10.88.0.0/16"
)

type networkCommandRunner interface {
	Run(name string, args ...string) error
}

type networkNamespaceOperations interface {
	Create(name, hostVeth, containerVeth, address string) error
	Delete(name string) error
}

type commandRunner struct{}

func (commandRunner) Run(name string, args ...string) error {
	output, err := exec.Command(name, args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s %s: %w: %s", name, strings.Join(args, " "), err, strings.TrimSpace(string(output)))
	}
	return nil
}

type containerNetwork struct {
	name       string
	address    string
	guestPorts []api.PublishedPort
}

type NetworkEndpoint struct {
	ContainerID string
	EndpointID  string
	Address     string
}

type managedNetwork struct {
	summary     api.NetworkSummary
	bridge      string
	nextAddress uint32
}

// NetworkManager owns one bridge and one preconfigured network namespace per
// container. The namespace exists before runc starts the process, so outbound
// networking is ready when the process executes its first instruction.
type NetworkManager struct {
	mu          sync.Mutex
	runner      networkCommandRunner
	namespaces  networkNamespaceOperations
	initialized bool
	nextAddress uint32
	nextPort    uint16
	createdAt   time.Time
	containers  map[string]*containerNetwork
	networks    map[string]*managedNetwork
}

func (m *NetworkManager) Path(id string) string {
	return "/run/netns/" + networkName(id)
}

func NewNetworkManager(runner networkCommandRunner) *NetworkManager {
	return newNetworkManager(runner, nativeNetworkNamespaceOperations{})
}

func newNetworkManager(runner networkCommandRunner, namespaces networkNamespaceOperations) *NetworkManager {
	return &NetworkManager{
		runner:      runner,
		namespaces:  namespaces,
		nextAddress: 2,
		nextPort:    41000,
		containers:  make(map[string]*containerNetwork),
		networks:    make(map[string]*managedNetwork),
	}
}

func (m *NetworkManager) Initialize() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.initialize()
}

func (m *NetworkManager) Create(id string) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if existing := m.containers[id]; existing != nil {
		return "/run/netns/" + existing.name, nil
	}
	if err := m.initialize(); err != nil {
		return "", err
	}
	if m.nextAddress >= 65535 {
		return "", errors.New("container bridge address space is exhausted")
	}
	name := networkName(id)
	address := fmt.Sprintf("10.88.%d.%d", m.nextAddress/256, m.nextAddress%256)
	m.nextAddress++
	hostVeth := "vh" + name[2:]
	containerVeth := "vc" + name[2:]
	if err := m.namespaces.Create(name, hostVeth, containerVeth, address); err != nil {
		_ = m.namespaces.Delete(name)
		return "", err
	}
	m.containers[id] = &containerNetwork{name: name, address: address}
	bridge := m.networks[bridgeName]
	if bridge != nil {
		if bridge.summary.Containers == nil {
			bridge.summary.Containers = make(map[string]api.NetworkContainer)
		}
		bridge.summary.Containers[id] = api.NetworkContainer{
			EndpointID:  name,
			IPv4Address: address + "/16",
		}
	}
	return "/run/netns/" + name, nil
}

func (m *NetworkManager) CreateNetwork(request api.NetworkCreateRequest) (api.NetworkSummary, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if request.Name == "" {
		return api.NetworkSummary{}, errors.New("network name is required")
	}
	if request.Name == "bridge" || request.Name == bridgeName {
		return api.NetworkSummary{}, fmt.Errorf("network %s already exists", request.Name)
	}
	if request.Driver != "" && request.Driver != "bridge" && request.Driver != "default" {
		return api.NetworkSummary{}, fmt.Errorf("unsupported network driver %s", request.Driver)
	}
	for _, network := range m.networks {
		if network.summary.Name == request.Name || network.summary.ID == request.Name {
			return api.NetworkSummary{}, fmt.Errorf("network %s already exists", request.Name)
		}
	}
	if err := m.initialize(); err != nil {
		return api.NetworkSummary{}, err
	}
	id := networkID(request.Name)
	subnet, gateway := networkSubnet(len(m.networks))
	config := api.NetworkIPAMConfig{Subnet: subnet, Gateway: gateway}
	if request.IPAM != nil && len(request.IPAM.Config) > 0 {
		config = request.IPAM.Config[0]
		if config.Subnet == "" {
			config.Subnet = subnet
		}
		if config.Gateway == "" {
			config.Gateway = gateway
		}
	}
	_, subnetNetwork, err := net.ParseCIDR(config.Subnet)
	if err != nil {
		return api.NetworkSummary{}, fmt.Errorf("invalid subnet %q: %w", config.Subnet, err)
	}
	bridge := networkBridgeName(id)
	prefix, _ := subnetNetwork.Mask.Size()
	commands := []string{
		"ip link add " + bridge + " type bridge",
		"ip addr add " + config.Gateway + "/" + strconv.Itoa(prefix) + " dev " + bridge,
		"ip link set " + bridge + " up",
	}
	if err := m.runner.Run("sh", "-c", strings.Join(commands, " && ")); err != nil {
		return api.NetworkSummary{}, err
	}
	driver := valueOr(request.Driver, "bridge")
	if driver == "default" {
		driver = "bridge"
	}
	summary := api.NetworkSummary{
		ID:         id,
		Name:       request.Name,
		CreatedAt:  time.Now().UTC(),
		Scope:      valueOr(request.Scope, "local"),
		Driver:     driver,
		EnableIPv4: boolOr(request.EnableIPv4, true),
		EnableIPv6: boolOr(request.EnableIPv6, false),
		Internal:   boolOr(request.Internal, false),
		Attachable: boolOr(request.Attachable, false),
		Ingress:    boolOr(request.Ingress, false),
		IPAM: api.NetworkIPAM{
			Driver: valueOrIPAMDriver(request.IPAM),
			Config: []api.NetworkIPAMConfig{config},
		},
		Options:    cloneStrings(request.Options),
		Containers: make(map[string]api.NetworkContainer),
		Labels:     cloneStrings(request.Labels),
	}
	m.networks[id] = &managedNetwork{summary: summary, bridge: bridge, nextAddress: 2}
	return cloneNetworkSummary(summary), nil
}

func (m *NetworkManager) Connect(
	networkID, containerID, containerName, ipv4Address, ipv6Address string, running bool,
) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	network := m.findNetworkLocked(networkID)
	if network == nil {
		return fmt.Errorf("network %s not found", networkID)
	}
	if running {
		return errors.New("network hot attach is not supported for running container")
	}
	if _, exists := m.containers[containerID]; !exists {
		return fmt.Errorf("container %s network namespace does not exist", containerID)
	}
	if _, exists := network.summary.Containers[containerID]; exists {
		return nil
	}
	if ipv4Address == "" {
		ipv4Address = allocateNetworkAddress(network)
	} else if ip := net.ParseIP(strings.Split(ipv4Address, "/")[0]); ip == nil || ip.To4() == nil {
		return fmt.Errorf("invalid IPv4 address %s", ipv4Address)
	}
	if containerName == "" {
		containerName = containerID
	}
	endpointID := networkEndpointID(network.summary.ID, containerID)
	network.summary.Containers[containerID] = api.NetworkContainer{
		Name:        containerName,
		EndpointID:  endpointID,
		IPv4Address: ipv4Address + "/16",
		IPv6Address: ipv6Address,
	}
	return nil
}

func (m *NetworkManager) Disconnect(networkID, containerID string, force bool) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	network := m.findNetworkLocked(networkID)
	if network == nil {
		return fmt.Errorf("network %s not found", networkID)
	}
	if network.summary.ID == bridgeName {
		return errors.New("cannot disconnect the default bridge network")
	}
	if _, exists := network.summary.Containers[containerID]; !exists {
		if force {
			return nil
		}
		return fmt.Errorf("container %s is not connected to network %s", containerID, network.summary.Name)
	}
	delete(network.summary.Containers, containerID)
	return nil
}

func (m *NetworkManager) Summaries(containerNames map[string]string) []api.NetworkSummary {
	m.mu.Lock()
	defer m.mu.Unlock()
	ids := make([]string, 0, len(m.networks))
	for id := range m.networks {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	result := make([]api.NetworkSummary, 0, len(ids))
	for _, id := range ids {
		summary := cloneNetworkSummary(m.networks[id].summary)
		for containerID, endpoint := range summary.Containers {
			if name := containerNames[containerID]; name != "" {
				endpoint.Name = name
				summary.Containers[containerID] = endpoint
			}
		}
		result = append(result, summary)
	}
	return result
}

func (m *NetworkManager) Publish(id string, requested []api.PublishedPort) ([]api.PublishedPort, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	network := m.containers[id]
	if network == nil {
		if len(requested) == 0 {
			return nil, nil
		}
		return nil, fmt.Errorf("private network does not exist for container %s", id)
	}
	if len(network.guestPorts) != 0 {
		if !publishedRequestMatches(network.guestPorts, requested) {
			return nil, fmt.Errorf("container %s already has a different published-port set", id)
		}
		return append([]api.PublishedPort(nil), network.guestPorts...), nil
	}
	published, err := m.normalizePublishedPorts(requested)
	if err != nil {
		return nil, err
	}
	installed := make([]api.PublishedPort, 0, len(published))
	selected := make(map[string]struct{}, len(published))
	for _, port := range published {
		key := port.Protocol + ":" + strconv.Itoa(int(port.GuestPort))
		if _, duplicate := selected[key]; duplicate {
			rollbackError := m.removeRules(network, installed)
			return nil, errors.Join(
				fmt.Errorf("published %s port %d is duplicated", port.Protocol, port.GuestPort),
				rollbackError,
			)
		}
		if conflictID, conflict := m.portOwner(port.GuestPort, port.Protocol); conflict {
			rollbackError := m.removeRules(network, installed)
			return nil, errors.Join(
				fmt.Errorf("published %s port %d is already owned by container %s", port.Protocol, port.GuestPort, conflictID),
				rollbackError,
			)
		}
		if err := m.addRules(network, port); err != nil {
			return nil, errors.Join(err, m.removeRules(network, installed))
		}
		installed = append(installed, port)
		selected[key] = struct{}{}
	}
	network.guestPorts = published
	return append([]api.PublishedPort(nil), published...), nil
}

func (m *NetworkManager) normalizePublishedPorts(requested []api.PublishedPort) ([]api.PublishedPort, error) {
	published := make([]api.PublishedPort, 0, len(requested))
	for _, port := range requested {
		protocol := strings.ToLower(port.Protocol)
		if protocol == "" {
			protocol = "tcp"
		}
		if (protocol != "tcp" && protocol != "udp") || port.ContainerPort == 0 {
			return nil, fmt.Errorf("unsupported published port %d/%s", port.ContainerPort, protocol)
		}
		guestPort := port.GuestPort
		if guestPort == 0 {
			var found bool
			for attempts := 0; attempts < 65535-41000+1; attempts++ {
				candidate := m.nextPort
				m.nextPort++
				if m.nextPort < 41000 {
					m.nextPort = 41000
				}
				if _, conflict := m.portOwner(candidate, protocol); !conflict {
					guestPort = candidate
					found = true
					break
				}
			}
			if !found {
				return nil, errors.New("published guest port range is exhausted")
			}
		}
		published = append(published, api.PublishedPort{ContainerPort: port.ContainerPort, GuestPort: guestPort, Protocol: protocol, HostSource: port.HostSource})
	}
	return published, nil
}

func (m *NetworkManager) portOwner(guestPort uint16, protocol string) (string, bool) {
	for id, network := range m.containers {
		for _, published := range network.guestPorts {
			if published.GuestPort == guestPort && published.Protocol == protocol {
				return id, true
			}
		}
	}
	return "", false
}

func (m *NetworkManager) Published(id string) []api.PublishedPort {
	m.mu.Lock()
	defer m.mu.Unlock()
	if network := m.containers[id]; network != nil {
		return append([]api.PublishedPort(nil), network.guestPorts...)
	}
	return nil
}

func (m *NetworkManager) Endpoints() []NetworkEndpoint {
	m.mu.Lock()
	defer m.mu.Unlock()
	ids := make([]string, 0, len(m.containers))
	for id := range m.containers {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	endpoints := make([]NetworkEndpoint, 0, len(ids))
	for _, id := range ids {
		network := m.containers[id]
		endpoints = append(endpoints, NetworkEndpoint{
			ContainerID: id,
			EndpointID:  network.name,
			Address:     network.address,
		})
	}
	return endpoints
}

func (m *NetworkManager) CreatedAt() time.Time {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.createdAt
}

func (m *NetworkManager) PublishedTCPDestination(guestPort uint16) (string, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, network := range m.containers {
		for _, published := range network.guestPorts {
			if published.Protocol == "tcp" && published.GuestPort == guestPort {
				return net.JoinHostPort(
					network.address,
					strconv.Itoa(int(published.ContainerPort)),
				), true
			}
		}
	}
	return "", false
}

func (m *NetworkManager) Delete(id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	network := m.containers[id]
	if network == nil {
		return nil
	}
	if err := m.removeRules(network, network.guestPorts); err != nil {
		return err
	}
	if err := m.namespaces.Delete(network.name); err != nil {
		return err
	}
	delete(m.containers, id)
	if bridge := m.networks[bridgeName]; bridge != nil {
		delete(bridge.summary.Containers, id)
	}
	return nil
}

func (m *NetworkManager) findNetworkLocked(id string) *managedNetwork {
	if network := m.networks[id]; network != nil {
		return network
	}
	for _, network := range m.networks {
		if network.summary.Name == id {
			return network
		}
	}
	return nil
}

func (m *NetworkManager) initialize() error {
	if m.initialized {
		return nil
	}
	commands := []string{
		"ip link add " + bridgeName + " type bridge",
		"ip addr add " + bridgeCIDR + " dev " + bridgeName,
		"ip link set " + bridgeName + " up",
		"sysctl -w net.ipv4.ip_forward=1",
		"iptables -t nat -A POSTROUTING -s " + networkCIDR + " ! -o " + bridgeName + " -j MASQUERADE",
		"iptables -A FORWARD -i " + bridgeName + " -j ACCEPT",
		"iptables -A FORWARD -o " + bridgeName + " -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT",
	}
	if err := m.runner.Run("sh", "-c", strings.Join(commands, " && ")); err != nil {
		return err
	}
	m.initialized = true
	m.createdAt = time.Now().UTC()
	m.networks[bridgeName] = &managedNetwork{
		bridge:      bridgeName,
		nextAddress: 2,
		summary: api.NetworkSummary{
			ID:         bridgeName,
			Name:       "bridge",
			CreatedAt:  m.createdAt,
			Scope:      "local",
			Driver:     "bridge",
			EnableIPv4: true,
			IPAM: api.NetworkIPAM{
				Driver: "default",
				Config: []api.NetworkIPAMConfig{{Subnet: networkCIDR, Gateway: "10.88.0.1"}},
			},
			Options:    map[string]string{},
			Containers: make(map[string]api.NetworkContainer),
			Labels:     map[string]string{},
		},
	}
	return nil
}

func cloneNetworkSummary(summary api.NetworkSummary) api.NetworkSummary {
	containers := make(map[string]api.NetworkContainer, len(summary.Containers))
	for id, container := range summary.Containers {
		containers[id] = container
	}
	return api.NetworkSummary{
		ID:         summary.ID,
		Name:       summary.Name,
		CreatedAt:  summary.CreatedAt,
		Scope:      summary.Scope,
		Driver:     summary.Driver,
		EnableIPv4: summary.EnableIPv4,
		EnableIPv6: summary.EnableIPv6,
		Internal:   summary.Internal,
		Attachable: summary.Attachable,
		Ingress:    summary.Ingress,
		IPAM:       summary.IPAM,
		Options:    cloneStrings(summary.Options),
		Containers: containers,
		Labels:     cloneStrings(summary.Labels),
	}
}

func cloneStrings(values map[string]string) map[string]string {
	if values == nil {
		return map[string]string{}
	}
	result := make(map[string]string, len(values))
	for key, value := range values {
		result[key] = value
	}
	return result
}

func valueOr(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}

func boolOr(value *bool, fallback bool) bool {
	if value == nil {
		return fallback
	}
	return *value
}

func valueOrIPAMDriver(value *api.NetworkIPAM) string {
	if value == nil || value.Driver == "" {
		return "default"
	}
	return value.Driver
}

func networkID(name string) string {
	digest := sha256.Sum256([]byte("network:" + name))
	return fmt.Sprintf("%x", digest[:])
}

func networkBridgeName(id string) string {
	return "gd" + id[:10]
}

func networkEndpointID(networkID, containerID string) string {
	digest := sha256.Sum256([]byte(networkID + ":" + containerID))
	return fmt.Sprintf("%x", digest[:8])
}

func networkSubnet(index int) (string, string) {
	third := 89 + index
	if third > 250 {
		third = 250
	}
	return fmt.Sprintf("10.%d.0.0/16", third), fmt.Sprintf("10.%d.0.1", third)
}

func allocateNetworkAddress(network *managedNetwork) string {
	address := network.nextAddress
	network.nextAddress++
	third := 89
	if len(network.summary.IPAM.Config) > 0 {
		if _, subnet, err := net.ParseCIDR(network.summary.IPAM.Config[0].Subnet); err == nil {
			bytes := subnet.IP.To4()
			if bytes != nil {
				third = int(bytes[1])
			}
		}
	}
	return fmt.Sprintf("10.%d.%d.%d", third, address/256, address%256)
}

func (m *NetworkManager) addRules(network *containerNetwork, port api.PublishedPort) error {
	rules := publicationRuleArguments("-A", network, port)
	for ruleIndex, rule := range rules {
		if err := m.runner.Run("iptables", rule...); err != nil {
			rollback := publicationRuleArguments("-D", network, port)
			var rollbackError error
			for installedIndex := ruleIndex - 1; installedIndex >= 0; installedIndex-- {
				rollbackError = errors.Join(
					rollbackError,
					m.runner.Run("iptables", rollback[installedIndex]...),
				)
			}
			return errors.Join(err, rollbackError)
		}
	}
	return nil
}

func (m *NetworkManager) removeRules(network *containerNetwork, ports []api.PublishedPort) error {
	var firstError error
	for portIndex := len(ports) - 1; portIndex >= 0; portIndex-- {
		rules := publicationRuleArguments("-D", network, ports[portIndex])
		for ruleIndex := len(rules) - 1; ruleIndex >= 0; ruleIndex-- {
			if err := m.runner.Run("iptables", rules[ruleIndex]...); err != nil && firstError == nil {
				firstError = err
			}
		}
	}
	return firstError
}

func publicationRuleArguments(operation string, network *containerNetwork, port api.PublishedPort) [][]string {
	guestPort := strconv.Itoa(int(port.GuestPort))
	containerPort := strconv.Itoa(int(port.ContainerPort))
	target := network.address + ":" + containerPort
	comment := "glassdock:" + network.name + ":" + port.Protocol + ":" + guestPort
	return [][]string{
		{"-t", "nat", operation, "PREROUTING", "-i", "eth0", "-p", port.Protocol, "--dport", guestPort, "-m", "comment", "--comment", comment, "-j", "DNAT", "--to-destination", target},
		{operation, "FORWARD", "-i", "eth0", "-o", bridgeName, "-p", port.Protocol, "-d", network.address, "--dport", containerPort, "-m", "conntrack", "--ctstate", "NEW,ESTABLISHED", "-m", "comment", "--comment", comment, "-j", "ACCEPT"},
		{operation, "FORWARD", "-i", bridgeName, "-o", "eth0", "-p", port.Protocol, "-s", network.address, "--sport", containerPort, "-m", "conntrack", "--ctstate", "ESTABLISHED", "-m", "comment", "--comment", comment, "-j", "ACCEPT"},
	}
}

func publishedRequestMatches(existing, requested []api.PublishedPort) bool {
	if len(existing) != len(requested) {
		return false
	}
	for index, request := range requested {
		protocol := strings.ToLower(request.Protocol)
		if protocol == "" {
			protocol = "tcp"
		}
		if existing[index].ContainerPort != request.ContainerPort ||
			existing[index].Protocol != protocol ||
			existing[index].HostSource != request.HostSource ||
			(request.GuestPort != 0 && existing[index].GuestPort != request.GuestPort) {
			return false
		}
	}
	return true
}

func networkName(id string) string {
	digest := sha256.Sum256([]byte(id))
	return fmt.Sprintf("st%x", digest[:6])
}
