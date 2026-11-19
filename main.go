package main

/*
#cgo LDFLAGS: -framework Security -framework CoreFoundation
#include <stdlib.h>
#include <Security/Security.h>

static OSStatus sshyard_find_generic(
	const char *service, UInt32 serviceLen,
	const char *account, UInt32 accountLen,
	UInt32 *length, void **data) {
	return SecKeychainFindGenericPassword(NULL, serviceLen, service, accountLen, account, length, data, NULL);
}

static void sshyard_free(void *data) {
	SecKeychainItemFreeContent(NULL, data);
}
*/
import "C"

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"unsafe"

	"golang.org/x/crypto/chacha20poly1305"
)

const (
	fileMagic   = "SSHYARD-SECRETS\x00"
	fileVersion = 1

	keychainService = "com.sshyard.desktop"
	keychainAccount = "master/v1"
)

func defaultPath(envKey, name string) string {
	if value := os.Getenv(envKey); value != "" {
		return value
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library", "Application Support", "SSHYard", name)
}

type host struct {
	ID           string `json:"id"`
	Name         string `json:"name"`
	Address      string `json:"address"`
	Port         int    `json:"port"`
	User         string `json:"user"`
	Group        string `json:"group"`
	Auth         string `json:"auth"`
	CredentialID string `json:"credentialId"`
}

type credential struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Kind string `json:"kind"`
}

type hostFile struct {
	Hosts       []host       `json:"hosts"`
	Credentials []credential `json:"credentials"`
}

func main() {
	list := flag.Bool("list", false, "list hosts without secrets")
	pick := flag.Bool("pick", false, "show a macOS picker listing all hosts")
	field := flag.String("field", "password", "password, passphrase or key")
	copyToClipboard := flag.Bool("copy", false, "copy the value to the clipboard instead of printing it")
	asJSON := flag.Bool("json", false, "print host details and the value as JSON")
	index := flag.Int("index", 0, "choose a host from the numbered matches")
	storePath := flag.String("store", defaultPath("SSHYARD_STORE", "secrets.enc"), "secrets.enc path")
	hostsPath := flag.String("hosts", defaultPath("SSHYARD_HOSTS", "hosts.json"), "hosts.json path")
	keyFile := flag.String("key-file", "", "read the 32-byte master key from this file instead of the keychain")
	exportKey := flag.String("export-key", "", "write the master key to this file (0600) and exit")
	scope := flag.String("scope", "", "override the secrets.enc scope")
	flag.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: sshyard-pass [flags] <ip-or-name|user@ip>")
		flag.PrintDefaults()
	}
	flag.CommandLine.Parse(interspersed(os.Args[1:]))

	if *exportKey != "" {
		key, err := masterKey(*keyFile)
		if err != nil {
			var friendly userError
			if errors.As(err, &friendly) {
				fmt.Println(friendly.message)
				return
			}
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		if err := writeKeyFile(*exportKey, key); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		fmt.Printf("主密钥已写入 %s\n", *exportKey)
		return
	}

	if err := run(*list, *pick, *field, *copyToClipboard, *asJSON, *index, *storePath, *hostsPath, *keyFile, *scope); err != nil {
		var friendly userError
		if errors.As(err, &friendly) {
			fmt.Println(friendly.message)
			return
		}
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

type userError struct{ message string }

func (e userError) Error() string { return e.message }

func explain(format string, args ...any) error {
	return userError{message: fmt.Sprintf(format, args...)}
}

// interspersed keeps flags usable after the positional argument, which the
// standard flag package does not allow.
func interspersed(args []string) []string {
	needsValue := map[string]bool{
		"field": true, "index": true, "store": true, "hosts": true,
		"key-file": true, "export-key": true, "scope": true,
	}
	var flags, positional []string
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if arg == "--" {
			positional = append(positional, args[i+1:]...)
			break
		}
		if len(arg) > 1 && arg[0] == '-' {
			flags = append(flags, arg)
			name := strings.TrimLeft(arg, "-")
			if eq := strings.IndexByte(name, '='); eq >= 0 {
				continue
			}
			if needsValue[name] && i+1 < len(args) {
				i++
				flags = append(flags, args[i])
			}
			continue
		}
		positional = append(positional, arg)
	}
	return append(flags, positional...)
}

func run(list, pick bool, field string, copyToClipboard, asJSON bool, index int, storePath, hostsPath, keyFile, scope string) error {
	file, err := loadHosts(hostsPath)
	if err != nil {
		return err
	}
	if list {
		printHosts(file.Hosts)
		return nil
	}
	var matches []host
	if pick {
		if len(file.Hosts) == 0 {
			return explain("SSHYard 里还没有主机")
		}
		chosen, err := pickHost(file.Hosts)
		if err != nil {
			return err
		}
		matches = []host{chosen}
	} else {
		if flag.NArg() != 1 {
			return explain("需要一个 IP、主机名或 user@ip，或用 --pick 从列表里选")
		}
		query := strings.TrimSpace(flag.Arg(0))
		if query == "" {
			return explain("输入为空")
		}
		matches = findHosts(file.Hosts, query)
	}
	if len(matches) == 0 {
		return explain("没有找到这台主机；用 --list 查看主机名和地址")
	}
	if len(matches) > 1 {
		if index < 1 || index > len(matches) {
			var b strings.Builder
			fmt.Fprintf(&b, "找到 %d 台主机，请用 user@ip、主机名或 --index 指定：\n", len(matches))
			for i, h := range matches {
				fmt.Fprintf(&b, "  %d. %s@%s  %s  [%s]\n", i+1, h.User, h.Address, h.Name, h.Auth)
			}
			return explain("%s", strings.TrimRight(b.String(), "\n"))
		}
		matches = matches[index-1 : index]
	}
	h := matches[0]

	key, err := masterKey(keyFile)
	if err != nil {
		return err
	}
	values, usedScope, err := openStore(storePath, key, scope)
	if err != nil {
		return err
	}
	_ = usedScope

	secretKey, err := secretKeyFor(file, h, field)
	if err != nil {
		return err
	}
	value, ok := values[secretKey]
	if !ok || len(value) == 0 {
		return explain("%s (%s@%s) 没有保存%s；可能导入时未勾选凭据", h.Name, h.User, h.Address, fieldName(field))
	}

	if copyToClipboard {
		if err := clipboard(value); err != nil {
			return err
		}
		fmt.Printf("已复制 %s (%s@%s) 的%s到剪贴板\n", h.Name, h.User, h.Address, fieldName(field))
		return nil
	}
	if asJSON {
		out, err := json.Marshal(struct {
			Name     string `json:"name"`
			Address  string `json:"address"`
			User     string `json:"user"`
			Port     int    `json:"port"`
			Group    string `json:"group"`
			Auth     string `json:"auth"`
			Field    string `json:"field"`
			Value    string `json:"value"`
		}{h.Name, h.Address, h.User, h.Port, h.Group, h.Auth, field, string(value)})
		if err != nil {
			return err
		}
		fmt.Print(string(out))
		return nil
	}
	os.Stdout.Write(value)
	return nil
}

func loadHosts(path string) (hostFile, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return hostFile{}, fmt.Errorf("读取 hosts.json 失败: %w", err)
	}
	var f hostFile
	if err := json.Unmarshal(data, &f); err != nil {
		return hostFile{}, fmt.Errorf("解析 hosts.json 失败: %w", err)
	}
	return f, nil
}

func printHosts(hosts []host) {
	sorted := append([]host(nil), hosts...)
	sort.Slice(sorted, func(i, j int) bool {
		if sorted[i].Address != sorted[j].Address {
			return sorted[i].Address < sorted[j].Address
		}
		return sorted[i].User < sorted[j].User
	})
	for _, h := range sorted {
		fmt.Printf("%-28s %-6s %-15s %-5d %-22s %s\n", h.Address, h.User, h.Auth, h.Port, h.Name, h.Group)
	}
}

func findHosts(hosts []host, query string) []host {
	q := strings.ToLower(query)
	var exact, partial []host
	for _, h := range hosts {
		userAt := strings.ToLower(h.User + "@" + h.Address)
		switch {
		case strings.ToLower(h.Address) == q, strings.ToLower(h.Name) == q, userAt == q:
			exact = append(exact, h)
		case strings.Contains(strings.ToLower(h.Address), q), strings.Contains(strings.ToLower(h.Name), q):
			partial = append(partial, h)
		}
	}
	if len(exact) > 0 {
		return exact
	}
	return partial
}

// pickHost shows the native macOS list picker and returns the chosen host.
func pickHost(hosts []host) (host, error) {
	sorted := append([]host(nil), hosts...)
	sort.Slice(sorted, func(i, j int) bool {
		if sorted[i].Address != sorted[j].Address {
			return sorted[i].Address < sorted[j].Address
		}
		return sorted[i].User < sorted[j].User
	})

	labels := make([]string, len(sorted))
	byLabel := make(map[string]int, len(sorted))
	for i, h := range sorted {
		port := ""
		if h.Port != 0 && h.Port != 22 {
			port = fmt.Sprintf(" :%d", h.Port)
		}
		label := fmt.Sprintf("%d. %s  %s  %s%s", i+1, h.Address, h.User, h.Name, port)
		if h.Group != "" {
			label += "  [" + h.Group + "]"
		}
		switch h.Auth {
		case "key":
			label += "  · 私钥"
		case "ask":
			label += "  · 每次询问"
		}
		labels[i] = label
		byLabel[label] = i
	}

	script := `on run argv
set picked to choose from list argv with title "SSHYard 密码" with prompt "选择要取密码的主机：" OK button name "获取密码" cancel button name "取消"
if picked is false then return ""
return item 1 of picked
end run`
	args := append([]string{"-e", script}, labels...)

	var stderr bytes.Buffer
	cmd := exec.Command("osascript", args...)
	cmd.Stderr = &stderr
	cmd.Stdin = nil
	out, err := cmd.Output()
	if err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) && strings.Contains(stderr.String(), "-128") {
			return host{}, explain("已取消")
		}
		return host{}, fmt.Errorf("打开选择框失败: %v %s", err, strings.TrimSpace(stderr.String()))
	}

	choice := strings.TrimSpace(string(out))
	if choice == "" {
		return host{}, explain("已取消")
	}
	i, ok := byLabel[choice]
	if !ok {
		return host{}, explain("没有识别到选择结果：%s", choice)
	}
	return sorted[i], nil
}

func secretKeyFor(f hostFile, h host, field string) (string, error) {
	switch h.Auth {
	case "password":
		if field != "password" {
			return "", explain("%s 是密码登录，没有%s", h.Name, fieldName(field))
		}
		return "host/" + h.ID + "/password", nil
	case "key":
		switch field {
		case "key":
			return "host/" + h.ID + "/key", nil
		case "passphrase":
			return "host/" + h.ID + "/passphrase", nil
		default:
			return "", explain("%s 是私钥登录，没有密码；可用 --field key 或 --field passphrase", h.Name)
		}
	case "credential":
		for _, c := range f.Credentials {
			if c.ID != h.CredentialID {
				continue
			}
			if c.Kind == "password" && field == "password" {
				return "cred/" + c.ID + "/password", nil
			}
			if c.Kind == "key" && field == "key" {
				return "cred/" + c.ID + "/key", nil
			}
			if c.Kind == "key" && field == "passphrase" {
				return "cred/" + c.ID + "/passphrase", nil
			}
			return "", explain("%s 使用凭据 %q，没有%s", h.Name, c.Name, fieldName(field))
		}
		return "", explain("%s 引用的凭据 %s 不存在", h.Name, h.CredentialID)
	case "ask", "agent":
		return "", explain("%s 没有保存密码（登录方式: %s）", h.Name, h.Auth)
	default:
		return "", explain("%s 的登录方式 %q 不受支持", h.Name, h.Auth)
	}
}

func fieldName(field string) string {
	switch field {
	case "key":
		return "私钥"
	case "passphrase":
		return "私钥口令"
	default:
		return "密码"
	}
}

func masterKey(keyFile string) ([]byte, error) {
	if keyFile == "" {
		if cached := cacheKeyPath(); cached != "" {
			if _, err := os.Stat(cached); err == nil {
				keyFile = cached
			}
		}
	}
	if keyFile != "" {
		key, err := os.ReadFile(keyFile)
		if err != nil {
			return nil, fmt.Errorf("读取主密钥文件失败: %w", err)
		}
		key = bytes.TrimSpace(key)
		if len(key) != chacha20poly1305.KeySize {
			return nil, fmt.Errorf("主密钥文件 %s 必须是 %d 字节", keyFile, chacha20poly1305.KeySize)
		}
		return key, nil
	}

	service := C.CString(keychainService)
	account := C.CString(keychainAccount)
	defer C.free(unsafe.Pointer(service))
	defer C.free(unsafe.Pointer(account))

	var length C.UInt32
	var data unsafe.Pointer
	status := C.sshyard_find_generic(
		service, C.UInt32(len(keychainService)),
		account, C.UInt32(len(keychainAccount)),
		&length, &data,
	)
	if status != 0 {
		switch status {
		case -128:
			return nil, errors.New("钥匙串读取被取消；请重试并在弹窗中允许")
		case -25300:
			return nil, errors.New("钥匙串里没有 master/v1；请先打开一次 SSHYard 并解锁")
		}
		return nil, fmt.Errorf("读取钥匙串主密钥失败 (OSStatus %d)", int(status))
	}
	defer C.sshyard_free(data)
	key := C.GoBytes(data, C.int(length))
	if len(key) != chacha20poly1305.KeySize {
		return nil, fmt.Errorf("钥匙串主密钥长度是 %d，不是 %d", len(key), chacha20poly1305.KeySize)
	}
	return key, nil
}

func cacheKeyPath() string {
	if value := os.Getenv("SSHYARD_KEY_CACHE"); value != "" {
		return value
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".local", "share", "sshyard-pass", "master.key")
}

func writeKeyFile(path string, key []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return fmt.Errorf("创建目录失败: %w", err)
	}
	temp, err := os.CreateTemp(filepath.Dir(path), ".master-*")
	if err != nil {
		return fmt.Errorf("创建临时文件失败: %w", err)
	}
	defer os.Remove(temp.Name())
	if err := temp.Chmod(0o600); err != nil {
		temp.Close()
		return fmt.Errorf("设置权限失败: %w", err)
	}
	if _, err := temp.Write(key); err != nil {
		temp.Close()
		return fmt.Errorf("写入主密钥失败: %w", err)
	}
	if err := temp.Close(); err != nil {
		return fmt.Errorf("写入主密钥失败: %w", err)
	}
	if err := os.Rename(temp.Name(), path); err != nil {
		return fmt.Errorf("写入主密钥失败: %w", err)
	}
	return nil
}

func openStore(path string, key []byte, scopeOverride string) (map[string][]byte, string, error) {
	sealed, err := os.ReadFile(path)
	if err != nil {
		return nil, "", fmt.Errorf("读取 secrets.enc 失败: %w", err)
	}
	header := len(fileMagic) + 1
	if len(sealed) < header+chacha20poly1305.NonceSizeX+chacha20poly1305.Overhead {
		return nil, "", errors.New("secrets.enc 太短或已损坏")
	}
	if !bytes.HasPrefix(sealed, []byte(fileMagic)) {
		return nil, "", errors.New("secrets.enc 格式不匹配")
	}
	if sealed[len(fileMagic)] != fileVersion {
		return nil, "", fmt.Errorf("secrets.enc 版本 %d 不受支持", sealed[len(fileMagic)])
	}

	aead, err := chacha20poly1305.NewX(key)
	if err != nil {
		return nil, "", err
	}
	scopes := []string{scopeOverride, "SSHYard", "sshyard", "com.sshyard.desktop", "SSHYard.app"}
	seen := map[string]bool{}
	for _, scope := range scopes {
		if seen[scope] {
			continue
		}
		seen[scope] = true
		aad := append([]byte(fileMagic), fileVersion)
		aad = append(aad, []byte(scope)...)
		plain, err := aead.Open(nil, sealed[header:header+chacha20poly1305.NonceSizeX], sealed[header+chacha20poly1305.NonceSizeX:], aad)
		if err != nil {
			continue
		}
		defer clear(plain)
		var values map[string][]byte
		if err := json.Unmarshal(plain, &values); err != nil || values == nil {
			return nil, "", errors.New("解密成功但内容不是有效的机密表")
		}
		return values, scope, nil
	}
	return nil, "", errors.New("无法解密 secrets.enc：主密钥与这个文件不匹配（SSHYard 可能重建过密钥，删掉 master.key 后重新导出一次）")
}

func clipboard(value []byte) error {
	cmd := exec.Command("pbcopy")
	cmd.Stdin = bytes.NewReader(value)
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("写入剪贴板失败: %w", err)
	}
	return nil
}

