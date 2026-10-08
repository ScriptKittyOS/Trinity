<!-- SPDX-FileCopyrightText: Sudo Apt Holdings LLC -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
# STIG applicability statement: the Trinity headless image

**Generated, not written.** `mix trinity.image.stig` derived this file from OpenSCAP's evaluation of
one built image; edit `ci/headless/stig_dispositions.yaml` and regenerate, never this file.

**This is a statement about an image, not a compliance determination.** It says, for each rule of
the DISA STIG profile for RHEL 9 that the SCAP Security Guide selects, whether this container image
meets it, why it does not apply to a container image, or why it belongs to the deployment that runs
the image. It is not a STIG compliance determination for any host, and it is not an authorization.

| | |
|---|---|
| Image | trinity-headless:otp7 (scripts/headless_image.sh build, 2026-10-08) |
| Image ID | sha256:1d2dcfe0fc9a62eb6b29e84ec65cd98fa4983aef771ca7a1b5616b536e298f58 |
| Profile | `xccdf_org.ssgproject.content_profile_stig` |
| SCAP Security Guide | 0.1.82 (`ssg-rhel9-ds.xml`) |
| Scanner | OpenSCAP 1.3.14 |
| Evaluated | 2026-10-08T13:42:22+00:00 |
| Deriving commands | `scripts/stig_scan.sh IMAGE OUT`, then `mix trinity.image.stig --results OUT/stig-results.xml --out PATH --image IMAGE --digest IMAGE_ID` |

477 rules selected. OpenSCAP: 2 fail, 410 notapplicable, 1 notchecked, 64 pass. Dispositions: 65 met,
410 not applicable, 2 the deployment's,
0 without one.

Every rule has a disposition.

| STIG ID | Rule | Severity | OpenSCAP | Disposition | Reason |
|---|---|---|---|---|---|
| RHEL-09-171011 | Set the GNOME3 Login Warning Banner Text | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_gdm holds |
| RHEL-09-211010 | The Installed Operating System Is Vendor Supported | high | pass | met | OpenSCAP: pass |
| RHEL-09-211015 | Ensure Software Patches Installed | medium | notchecked | met | The build runs dnf upgrade against the image's root filesystem, so every vendor package is the newest build UBI's repositories carry when the image is built; OpenSCAP reports notchecked because the guide ships no errata data to check against. Patches published after a build reach the image when it is rebuilt. Components outside the vendor's packages are covered by the image's vulnerability scan (mix trinity.image.findings), not by this rule. |
| RHEL-09-211020 | Modify the System Login Banner | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-211030 | Disable Graphical Environment Startup By Setting Default Target | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-211040 | Enable systemd-journald Service | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-211045 | Disable Ctrl-Alt-Del Burst Action | high | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_systemd hold |
| RHEL-09-211050 | Disable Ctrl-Alt-Del Reboot Activation | high | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-211055 | Disable debug-shell SystemD Service | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-212010 | Set Boot Loader Password in grub2 | high | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where grub2_and_system_with_kernel and not_container hold |
| RHEL-09-212015 | Verify that Interactive Boot is Disabled | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and grub2 hold |
| RHEL-09-212020 | Set the Boot Loader Admin Username to a Non-Default Value | high | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where grub2_and_system_with_kernel holds |
| RHEL-09-212025 | Verify /boot/grub2/grub.cfg Group Ownership | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where grub2_and_system_with_kernel and not_container hold |
| RHEL-09-212030 | Verify /boot/grub2/grub.cfg User Ownership | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where grub2_and_system_with_kernel and not_container hold |
| RHEL-09-212035 | Disable vsyscalls | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where grub2_and_system_with_kernel and x86_64_arch hold |
| RHEL-09-212040 | Enable page allocator poisoning | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and grub2 hold |
| RHEL-09-212045 | The system must booted with init_on_free=1 | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where grub2_and_system_with_kernel and grub2 hold |
| RHEL-09-212050 | Enable Kernel Page-Table Isolation (KPTI) | low | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where grub2_and_system_with_kernel holds |
| RHEL-09-212055 | Enable Auditing for Processes Which Start Prior to the Audit Daemon | low | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and grub2 hold |
| RHEL-09-213010 | Restrict Access to Kernel Message Buffer | low | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-213015 | Disallow kernel profiling by unprivileged users | low | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-213020 | Disable Kernel Image Loading | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-213025 | Restrict Exposed Kernel Pointer Addresses Access | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-213030 | Enable Kernel Parameter to Enforce DAC on Hardlinks | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-213035 | Enable Kernel Parameter to Enforce DAC on Symlinks | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-213040 | Disable storing core dumps | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-213045 | Disable ATM Support | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-213050 | Disable CAN Support | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-213055 | Disable IEEE 1394 (FireWire) Support | low | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-213060 | Disable SCTP Support | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-213065 | Disable TIPC Support | low | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-213070 | Enable Randomized Layout of Virtual Address Space | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-213075 | Disable Access to Network bpf() Syscall From Unprivileged Processes | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-213080 | Restrict usage of ptrace to descendant processes | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-213105 | Disable the use of user namespaces | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-213110 | Enable ExecShield via sysctl | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel_and_x86_64_arch holds |
| RHEL-09-213115 | Disable KDump Kernel Crash Analyzer (kdump) | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-214010 | Ensure Red Hat GPG Key Installed | high | pass | met | OpenSCAP: pass |
| RHEL-09-214015 | Ensure gpgcheck Enabled In Main dnf Configuration | high | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_dnf holds |
| RHEL-09-214020 | Ensure gpgcheck Enabled for Local Packages | high | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_dnf holds |
| RHEL-09-214025 | Ensure gpgcheck Enabled for All dnf Package Repositories | high | pass | met | OpenSCAP: pass |
| RHEL-09-214035 | Ensure dnf Removes Previous Package Versions | low | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_bootc_and_package_dnf holds |
| RHEL-09-215010 | Install subscription-manager Package | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-215015 | Uninstall vsftpd Package | high | pass | met | OpenSCAP: pass |
| RHEL-09-215020 | Uninstall Sendmail Package | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-215025 | Uninstall nfs-utils Package | low | pass | met | OpenSCAP: pass |
| RHEL-09-215035 | Ensure EPEL Repository is Disabled | medium | pass | met | OpenSCAP: pass |
| RHEL-09-215040 | Uninstall telnet-server Package | high | pass | met | OpenSCAP: pass |
| RHEL-09-215045 | Uninstall gssproxy Package | medium | pass | met | OpenSCAP: pass |
| RHEL-09-215050 | Uninstall iprutils Package | medium | pass | met | OpenSCAP: pass |
| RHEL-09-215055 | Uninstall tuned Package | medium | pass | met | OpenSCAP: pass |
| RHEL-09-215060 | Uninstall tftp-server Package | high | pass | met | OpenSCAP: pass |
| RHEL-09-215070 | Disable graphical user interface | medium | pass | met | OpenSCAP: pass |
| RHEL-09-215075 | Install Smart Card Packages For Multifactor Authentication | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and not_s390x_arch hold |
| RHEL-09-215080 | Ensure gnutls-utils is installed | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-215085 | Ensure nss-tools is installed | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-215090 | Install rng-tools Package | low | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_runtime_kernel_fips_enabled_and_system_with_kernel holds |
| RHEL-09-215095 | The s-nail Package Is Installed | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-215100 | Install crypto-policies package | medium | pass | met | OpenSCAP: pass |
| RHEL-09-215101 | The Postfix package is installed | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-215105, RHEL-09-672030 | Configure System Cryptography Policy | high | fail | the deployment's | The system-wide crypto policy (FIPS:STIG) goes with FIPS mode, which is a property of the host kernel and of how the container is run (docs/fips-leg.md), so the deployment sets it. The image's own TLS is OTP's ssl application, which crypto-policies has no back-end for; the crypto NIF links the base's OpenSSL, whose FIPS provider the deployment's FIPS mode enables. |
| RHEL-09-215105 | FIPS Must Use a Supported Subpolicy | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-215105 | Implement STIG Sub Crypto Policy | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-231010 | Ensure /home Located On Separate Partition | low | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_bootc_and_not_container holds |
| RHEL-09-231015 | Ensure /tmp Located On Separate Partition | low | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_bootc_and_not_container holds |
| RHEL-09-231020 | Ensure /var Located On Separate Partition | low | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_bootc_and_not_container holds |
| RHEL-09-231025 | Ensure /var/log Located On Separate Partition | low | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_bootc_and_not_container holds |
| RHEL-09-231030 | Ensure /var/log/audit Located On Separate Partition | low | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_bootc_and_not_container holds |
| RHEL-09-231035 | Ensure /var/tmp Located On Separate Partition | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_bootc_and_not_container holds |
| RHEL-09-231040 | Disable the Automounter | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_autofs_and_system_with_kernel holds |
| RHEL-09-231045 | Add nodev Option to /home | unknown | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_bootc_and_not_container and mount_home hold |
| RHEL-09-231050 | Add nosuid Option to /home | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_bootc_and_not_container and mount_home hold |
| RHEL-09-231055 | Add noexec Option to /home | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_bootc_and_not_container holds |
| RHEL-09-231065 | Mount Remote Filesystems with nodev | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and nfs_mount_defined hold |
| RHEL-09-231070 | Mount Remote Filesystems with noexec | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and nfs_mount_defined hold |
| RHEL-09-231075 | Mount Remote Filesystems with nosuid | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and nfs_mount_defined hold |
| RHEL-09-231080 | Add noexec Option to Removable Media Partitions | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_bootc_and_not_container holds |
| RHEL-09-231085 | Add nodev Option to Removable Media Partitions | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_bootc_and_not_container holds |
| RHEL-09-231090 | Add nosuid Option to Removable Media Partitions | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_bootc_and_not_container holds |
| RHEL-09-231095 | Add nodev Option to /boot | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_bootc_and_not_container holds |
| RHEL-09-231100 | Add nosuid Option to /boot | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_bootc_and_not_container holds |
| RHEL-09-231105 | Add nosuid Option to /boot/efi | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_bootc_and_not_container and mount_boot-efi hold |
| RHEL-09-231110 | Add nodev Option to /dev/shm | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_bootc_and_not_container holds |
| RHEL-09-231115 | Add noexec Option to /dev/shm | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_bootc_and_not_container holds |
| RHEL-09-231120 | Add nosuid Option to /dev/shm | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_bootc_and_not_container holds |
| RHEL-09-231125 | Add nodev Option to /tmp | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_bootc_and_not_container and mount_tmp hold |
| RHEL-09-231130 | Add noexec Option to /tmp | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_bootc_and_not_container and mount_tmp hold |
| RHEL-09-231135 | Add nosuid Option to /tmp | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_bootc_and_not_container and mount_tmp hold |
| RHEL-09-231140 | Add nodev Option to /var | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_bootc_and_not_container and mount_var hold |
| RHEL-09-231145 | Add nodev Option to /var/log | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_bootc_and_not_container and mount_var-log hold |
| RHEL-09-231150 | Add noexec Option to /var/log | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_bootc_and_not_container and mount_var-log hold |
| RHEL-09-231155 | Add nosuid Option to /var/log | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_bootc_and_not_container and mount_var-log hold |
| RHEL-09-231160 | Add nodev Option to /var/log/audit | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_bootc_and_not_container and mount_var-log-audit hold |
| RHEL-09-231165 | Add noexec Option to /var/log/audit | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_bootc_and_not_container and mount_var-log-audit hold |
| RHEL-09-231170 | Add nosuid Option to /var/log/audit | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_bootc_and_not_container and mount_var-log-audit hold |
| RHEL-09-231175 | Add nodev Option to /var/tmp | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_bootc_and_not_container and mount_var-tmp hold |
| RHEL-09-231180 | Add noexec Option to /var/tmp | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_bootc_and_not_container and mount_var-tmp hold |
| RHEL-09-231185 | Add nosuid Option to /var/tmp | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_bootc_and_not_container and mount_var-tmp hold |
| RHEL-09-231190 | Encrypt Partitions | high | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_bootc_and_not_container holds |
| RHEL-09-231195 | Disable Mounting of cramfs | low | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-231200 | Add nodev Option to Non-Root Local Partitions | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_bootc_and_not_container holds |
| RHEL-09-232010 | Verify that System Executables Have Restrictive Permissions | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232015 | Verify that Shared Library Directories Have Restrictive Permissions | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232020 | Verify that Shared Library Files Have Restrictive Permissions | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232025 | Verify Permissions on /var/log Directory | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232030 | Verify Permissions on /var/log/messages File | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232035 | Audit Tools Must Have a Mode of 0755 or Less Permissive | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-232040 | Verify Permissions on Cron Configuration Files Are Not Modified | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-232045 | Ensure All User Initialization Files Have Mode 0740 Or Less Permissive | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232045 | Ensure rootfiles tmpfile.d is Configured Correctly | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_rootfiles holds |
| RHEL-09-232050 | All Interactive User Home Directories Must Have mode 0750 Or Less Permissive | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232055 | Verify Permissions on group File | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232060 | Verify Permissions on Backup group File | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232065 | Verify Permissions on gshadow File | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232070 | Verify Permissions on Backup gshadow File | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232075 | Verify Permissions on passwd File | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232080 | Verify Permissions on Backup passwd File | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232085 | Verify Permissions on Backup shadow File | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232090 | Verify User Who Owns group File | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232095 | Verify Group Who Owns group File | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232100 | Verify User Who Owns Backup group File | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232103 | Audit Configuration Files Must Be Owned By Root | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-232104 | Audit Configuration Files Must Be Owned By Group root | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-232105 | Verify Group Who Owns Backup group File | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232110 | Verify User Who Owns gshadow File | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232115 | Verify Group Who Owns gshadow File | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232120 | Verify User Who Owns Backup gshadow File | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232125 | Verify Group Who Owns Backup gshadow File | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232130 | Verify User Who Owns passwd File | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232135 | Verify Group Who Owns passwd File | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232140 | Verify User Who Owns Backup passwd File | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232145 | Verify Group Who Owns Backup passwd File | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232150 | Verify User Who Owns shadow File | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232155 | Verify Group Who Owns shadow File | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232160 | Verify Group Who Owns Backup shadow File | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232165 | Verify User Who Owns Backup shadow File | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232170 | Verify User Who Owns /var/log Directory | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232175 | Verify Group Who Owns /var/log Directory | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232180 | Verify User Who Owns /var/log/messages File | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232185 | Verify Group Who Owns /var/log/messages File | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232190 | Verify that System Executables Have Root Ownership | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232195 | Verify that system commands files are group owned by root or a system account | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232200 | Verify that Shared Library Files Have Root Ownership | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232205 | Verify the system-wide library files in directories "/lib", "/lib64", "/usr/lib/" and "/usr/lib64" are group-owned by root. | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232210 | Verify that Shared Library Directories Have Root Ownership | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232215 | Verify that Shared Library Directories Have Root Group Ownership | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232220 | Audit Tools Must Be Owned by Root | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-232225 | Audit Tools Must Be Group-owned by Root | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-232230 | Verify Owner on cron.d | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-232230 | Verify Owner on cron.daily | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-232230 | Verify Owner on cron.deny | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-232230 | Verify Owner on cron.hourly | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-232230 | Verify Owner on cron.monthly | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-232230 | Verify Owner on cron.weekly | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-232230 | Verify Owner on crontab | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-232235 | Verify Group Who Owns cron.d | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-232235 | Verify Group Who Owns cron.daily | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-232235 | Verify Group Who Owns cron.deny | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-232235 | Verify Group Who Owns cron.hourly | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-232235 | Verify Group Who Owns cron.monthly | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-232235 | Verify Group Who Owns cron.weekly | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-232235 | Verify Group Who Owns Crontab | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-232240 | Ensure All World-Writable Directories Are Owned by a System Account | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232245 | Verify that All World-Writable Directories Have Sticky Bits Set | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232250 | Ensure All Files Are Owned by a Group | medium | pass | met | OpenSCAP: pass |
| RHEL-09-232255 | Ensure All Files Are Owned by a User | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-232260 | Ensure No Device Files are Unlabeled by SELinux | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-232270 | Verify Permissions on shadow File | medium | pass | met | OpenSCAP: pass |
| RHEL-09-251010 | Install firewalld Package | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-251015 | Verify firewalld Enabled | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_firewalld hold |
| RHEL-09-251020 | Firewalld Must Employ a Deny-all, Allow-by-exception Policy for Allowing Connections to Other Systems | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-251030 | Configure Firewalld to Use the Nftables Backend | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_firewalld hold |
| RHEL-09-251035 | Enable SSH Server firewalld Firewall Exception | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-251040 | Ensure System is Not Acting as a Network Sniffer | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where machine holds |
| RHEL-09-251045 | Harden the operation of the BPF just-in-time compiler | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-252010 | The Chrony package is installed | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-252015 | The Chronyd service is enabled | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_chrony hold |
| RHEL-09-252020 | Configure Time Service Maxpoll Interval | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_chrony_or_package_ntp hold |
| RHEL-09-252020 | Ensure Chrony is only configured with the server directive | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_chrony hold |
| RHEL-09-252020 | A remote time server for Chrony is configured | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_chrony hold |
| RHEL-09-252025 | Disable chrony daemon from acting as server | low | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_chrony hold |
| RHEL-09-252030 | Configure chrony-wait.service to use Unix socket | low | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_chrony hold |
| RHEL-09-252030 | Disable network management of chrony daemon | low | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_chrony hold |
| RHEL-09-252035 | Configure Multiple DNS Servers in /etc/resolv.conf | medium | fail | the deployment's | A container's /etc/resolv.conf is written by the container runtime from the deployment's DNS configuration (the kubelet, or the engine), not taken from the image, so the number of name servers is the deployment's. |
| RHEL-09-252040 | NetworkManager DNS Mode Must Be Must Configured | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_networkmanager holds |
| RHEL-09-252045 | Verify Any Configured IPSec Tunnel Connections | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-252050 | Prevent Unrestricted Mail Relaying | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_postfix hold |
| RHEL-09-252060 | Configure System to Forward All Mail From Postmaster to The Root Account | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-252065 | Install libreswan Package | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-252070 | Remove Host-Based Authentication Files | high | pass | met | OpenSCAP: pass |
| RHEL-09-252075 | Remove User Host-Based Authentication Files | high | pass | met | OpenSCAP: pass |
| RHEL-09-253010 | Enable Kernel Parameter to Use TCP Syncookies on Network Interfaces | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-253015 | Disable Accepting ICMP Redirects for All IPv4 Interfaces | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-253020 | Disable Kernel Parameter for Accepting Source-Routed Packets on all IPv4 Interfaces | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-253025 | Enable Kernel Parameter to Log Martian Packets on all IPv4 Interfaces | unknown | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-253030 | Enable Kernel Parameter to Log Martian Packets on all IPv4 Interfaces by Default | unknown | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-253035 | Enable Kernel Parameter to Use Reverse Path Filtering on all IPv4 Interfaces | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-253040 | Disable Kernel Parameter for Accepting ICMP Redirects by Default on IPv4 Interfaces | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-253045 | Disable Kernel Parameter for Accepting Source-Routed Packets on IPv4 Interfaces by Default | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-253050 | Enable Kernel Parameter to Use Reverse Path Filtering on all IPv4 Interfaces by Default | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-253055 | Enable Kernel Parameter to Ignore ICMP Broadcast Echo Requests on IPv4 Interfaces | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-253060 | Enable Kernel Parameter to Ignore Bogus ICMP Error Responses on IPv4 Interfaces | unknown | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-253065 | Disable Kernel Parameter for Sending ICMP Redirects on all IPv4 Interfaces | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-253070 | Disable Kernel Parameter for Sending ICMP Redirects on all IPv4 Interfaces by Default | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-253075 | Disable Kernel Parameter for IPv4 Forwarding on all IPv4 Interfaces | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-254010 | Configure Accepting Router Advertisements on All IPv6 Interfaces | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where ipv6_enabled and system_with_kernel hold |
| RHEL-09-254015 | Disable Accepting ICMP Redirects for All IPv6 Interfaces | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where ipv6_enabled and system_with_kernel hold |
| RHEL-09-254020 | Disable Kernel Parameter for Accepting Source-Routed Packets on all IPv6 Interfaces | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where ipv6_enabled and system_with_kernel hold |
| RHEL-09-254025 | Disable Kernel Parameter for IPv6 Forwarding | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where ipv6_enabled and system_with_kernel hold |
| RHEL-09-254030 | Disable Accepting Router Advertisements on all IPv6 Interfaces by Default | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where ipv6_enabled and system_with_kernel hold |
| RHEL-09-254035 | Disable Kernel Parameter for Accepting ICMP Redirects by Default on IPv6 Interfaces | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where ipv6_enabled and system_with_kernel hold |
| RHEL-09-254040 | Disable Kernel Parameter for Accepting Source-Routed Packets on IPv6 Interfaces by Default | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where ipv6_enabled and system_with_kernel hold |
| RHEL-09-255010 | Install the OpenSSH Server Package | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-255015 | Enable the OpenSSH Service | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-255020 | Install OpenSSH client software | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-255025 | Enable SSH Warning Banner | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-255030 | Set SSH Daemon LogLevel to VERBOSE | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-255035 | Enable Public Key Authentication | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-255040 | Disable SSH Access via Empty Passwords | high | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-255045 | Disable SSH Root Login | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-255050 | Enable PAM | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-255064 | Configure SSH Client to Use FIPS 140 Validated Ciphers: openssh.config | high | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_openssh holds |
| RHEL-09-255065 | Configure SSH Server to Use FIPS 140-2 Validated Ciphers: opensshserver.config | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-255065 | SSHD Must Include System Crypto Policy Config File | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-255070 | Configure SSH Client to Use FIPS 140-2 Validated MACs: openssh.config | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_openssh holds |
| RHEL-09-255075 | Configure SSH Server to Use FIPS 140-2 Validated MACs: opensshserver.config | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-255080 | Disable Host-Based Authentication | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-255085 | Do Not Allow SSH Environment Options | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-255090 | Force frequent session key renegotiation | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-255095 | Set SSH Client Alive Count Max | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-255100 | Set SSH Client Alive Interval | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-255105 | Verify Group Who Owns SSH Server Configuration Files | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-255105 | Verify Group Who Owns SSH Server config file | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-255105 | Verify Group Who Owns SSH Server Configuration Files | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-255105, RHEL-09-255110 | The File /etc/ssh/sshd_config.d/50-redhat.conf Must Exist | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-255110 | Verify Owner on SSH Server Configuration Files | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-255110 | Verify Owner on SSH Server config file | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-255110 | Verify Owner on SSH Server Configuration Files | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-255115 | Verify Permissions on SSH Server Config File | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-255115 | Verify Permissions on SSH Server config file | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-255115 | Verify Permissions on SSH Server Config File | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-255120 | Verify Permissions on SSH Server Private *_key Key Files | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-255125 | Verify Permissions on SSH Server Public *.pub Key Files | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-255135 | Disable GSSAPI Authentication | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-255140 | Disable Kerberos Authentication | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-255145 | Disable SSH Support for .rhosts Files | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-255150 | Disable SSH Support for User Known Hosts | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-255155 | Disable X11 Forwarding | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-255160 | Enable Use of Strict Mode Checking | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-255165 | Enable SSH Print Last Log | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-255175 | Prevent remote hosts from connecting to the proxy display | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-271010, RHEL-09-271015 | Enable GNOME3 Login Warning Banner | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_gdm holds |
| RHEL-09-271020, RHEL-09-271025 | Disable GNOME3 Automount Opening | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_gdm holds |
| RHEL-09-271030, RHEL-09-271035 | Disable GNOME3 Automount running | low | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_gdm holds |
| RHEL-09-271040 | Disable GDM Automatic Login | high | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_gdm holds |
| RHEL-09-271045, RHEL-09-271050 | Enable the GNOME3 Screen Locking On Smartcard Removal | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_gdm holds |
| RHEL-09-271055, RHEL-09-271060 | Enable GNOME3 Screensaver Lock After Idle Period | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_gdm holds |
| RHEL-09-271065 | Set GNOME3 Screensaver Inactivity Timeout | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_gdm holds |
| RHEL-09-271070 | Ensure Users Cannot Change GNOME3 Session Idle Settings | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_gdm holds |
| RHEL-09-271075 | Set GNOME3 Screensaver Lock Delay After Activation Period | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_gdm holds |
| RHEL-09-271080 | Ensure Users Cannot Change GNOME3 Screensaver Settings | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_gdm holds |
| RHEL-09-271085 | Implement Blank Screensaver | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_gdm holds |
| RHEL-09-271090 | Make sure that the dconf databases are up-to-date with regards to respective keyfiles | high | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_gdm and system_with_kernel hold |
| RHEL-09-271095, RHEL-09-271100 | Disable the GNOME3 Login Restart and Shutdown Buttons | high | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_gdm holds |
| RHEL-09-271105, RHEL-09-271110 | Disable Ctrl-Alt-Del Reboot Key Sequence in GNOME3 | high | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_gdm holds |
| RHEL-09-271115 | Disable the GNOME3 Login User List | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_gdm holds |
| RHEL-09-291010 | Disable Modprobe Loading of USB Storage Driver | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-291015 | Install usbguard Package | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_s390x_arch_and_system_with_kernel holds |
| RHEL-09-291020 | Enable the USBGuard Service | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_s390x_arch_and_system_with_kernel holds |
| RHEL-09-291025 | Log USBGuard daemon audit events using Linux Audit | low | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_s390x_arch_and_system_with_kernel and package_usbguard hold |
| RHEL-09-291030 | Generate USBGuard Policy | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_s390x_arch_and_system_with_kernel holds |
| RHEL-09-291035 | Disable Bluetooth Kernel Module | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-291040 | Deactivate Wireless Network Interfaces | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_container_and_wifi-iface holds |
| RHEL-09-411010 | Set Password Maximum Age | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_shadow-utils hold |
| RHEL-09-411015 | Set Existing Passwords Maximum Age | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-411020 | Ensure Home Directories are Created for New Users | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_shadow-utils_and_system_with_kernel holds |
| RHEL-09-411025 | Ensure the Default Umask is Set Correctly For Interactive Users | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-411030 | Ensure All Accounts on the System Have Unique User IDs | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-411035 | Ensure that System Accounts Do Not Run a Shell Upon Login | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-411040 | Assign Expiration Date to Temporary Accounts | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-411045 | All GIDs referenced in /etc/passwd must be defined in /etc/group | low | pass | met | OpenSCAP: pass |
| RHEL-09-411050 | Set Account Expiration Following Inactivity | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_shadow-utils hold |
| RHEL-09-411055 | Ensure that Users Path Contains Only Local Directories | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-411060 | All Interactive Users Must Have A Home Directory Defined | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-411065 | All Interactive Users Home Directories Must Exist | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-411070 | All Interactive User Home Directories Must Be Group-Owned By The Primary Group | medium | pass | met | OpenSCAP: pass |
| RHEL-09-411075 | Lock Accounts After Failed Password Attempts | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_pam hold |
| RHEL-09-411080 | Configure the root Account for Failed Password Attempts | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_pam hold |
| RHEL-09-411085 | Set Interval For Counting Failed Password Attempts | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_pam hold |
| RHEL-09-411090 | Set Lockout Time for Failed Password Attempts | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_pam hold |
| RHEL-09-411095 | Only Authorized Local User Accounts Exist on Operating System | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-411100 | Verify Only Root Has UID 0 | high | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-411105 | Lock Accounts Must Persist | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_pam hold |
| RHEL-09-411110 | Ensure All Groups on the System Have Unique Group ID | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-412035 | Set Interactive Session Timeout | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-412040 | Limit the Number of Concurrent Login Sessions Allowed Per User | low | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_pam_and_system_with_kernel holds |
| RHEL-09-412045 | Account Lockouts Must Be Logged | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_pam hold |
| RHEL-09-412050 | Ensure the Logon Failure Delay is Set Correctly in login.defs | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_shadow-utils_and_system_with_kernel holds |
| RHEL-09-412055 | Ensure the Default Bash Umask is Set Correctly | medium | pass | met | OpenSCAP: pass |
| RHEL-09-412060 | Ensure the Default C Shell Umask is Set Correctly | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_tcsh holds |
| RHEL-09-412065 | Ensure the Default Umask is Set Correctly in login.defs | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_shadow-utils_and_system_with_kernel holds |
| RHEL-09-412070 | Ensure the Default Umask is Set Correctly in /etc/profile | medium | pass | met | OpenSCAP: pass |
| RHEL-09-412080 | Configure Logind to terminate idle sessions after certain time of inactivity | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and os_linux_ol_gt_or_eq_8_7 and os_linux_rhel_gt_or_eq_8_7_and_os_linux_rhel_ne_9_0 and os_linux_sles_gt_or_eq_15 hold |
| RHEL-09-431010 | Ensure SELinux State is Enforcing | high | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-431015 | Configure SELinux Policy | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-431016 | Elevate The SELinux Context When An Administrator Calls The Sudo Command | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-431020 | An SELinux Context must be configured for the pam_faillock.so records directory | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-431025 | Install policycoreutils Package | low | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-431030 | Install policycoreutils-python-utils package | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-432010 | Install sudo Package | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-432015 | Require Re-Authentication When Using the sudo Command | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_sudo hold |
| RHEL-09-432020 | Ensure invoking users password for privilege escalation when using sudo | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_sudo hold |
| RHEL-09-432025 | Ensure Users Re-Authenticate for Privilege Escalation - sudo !authenticate | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-432030 | The operating system must restrict privilege elevation to authorized personnel | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_sudo hold |
| RHEL-09-432035 | Enforce usage of pam_wheel for su authentication | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_pam holds |
| RHEL-09-433010 | Install fapolicyd Package | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-433015 | Enable the File Access Policy Service | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-433016 | Configure Fapolicy Module to Employ a Deny-all, Permit-by-exception Policy to Allow the Execution of Authorized Software Programs. | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-611010 | Ensure PAM Enforces Password Requirements - Authentication Retry Prompts Permitted Per-Session in /etc/security/pwquality.conf | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-611025 | Prevent Login to Accounts With Empty Password | high | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-611030 | Configure the Use of the pam_faillock.so Module in the /etc/pam.d/system-auth File. | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-611035 | Configure the Use of the pam_faillock.so Module in the /etc/pam.d/password-auth File. | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-611040 | Ensure PAM password complexity module is enabled in password-auth | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_libpwquality hold |
| RHEL-09-611045 | Ensure PAM password complexity module is enabled in system-auth | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_libpwquality hold |
| RHEL-09-611050 | Set number of Password Hashing Rounds - password-auth | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_pam_and_system_with_kernel holds |
| RHEL-09-611055 | Set number of Password Hashing Rounds - system-auth | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_pam_and_system_with_kernel holds |
| RHEL-09-611060 | Ensure PAM Enforces Password Requirements - Enforce for root User | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_libpwquality hold |
| RHEL-09-611065 | Ensure PAM Enforces Password Requirements - Minimum Lowercase Characters | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_libpwquality hold |
| RHEL-09-611070 | Ensure PAM Enforces Password Requirements - Minimum Digit Characters | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_libpwquality hold |
| RHEL-09-611075 | Set Password Minimum Age | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_shadow-utils hold |
| RHEL-09-611080 | Set Existing Passwords Minimum Age | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-611085 | Ensure Users Re-Authenticate for Privilege Escalation - sudo NOPASSWD | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-611090 | Ensure PAM Enforces Password Requirements - Minimum Length | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_libpwquality hold |
| RHEL-09-611100 | Ensure PAM Enforces Password Requirements - Minimum Special Characters | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_libpwquality hold |
| RHEL-09-611105 | Ensure PAM Enforces Password Requirements - Prevent the Use of Dictionary Words | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_libpwquality hold |
| RHEL-09-611110 | Ensure PAM Enforces Password Requirements - Minimum Uppercase Characters | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_libpwquality hold |
| RHEL-09-611115 | Ensure PAM Enforces Password Requirements - Minimum Different Characters | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_libpwquality hold |
| RHEL-09-611120 | Ensure PAM Enforces Password Requirements - Maximum Consecutive Repeating Characters from Same Character Class | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_libpwquality hold |
| RHEL-09-611125 | Set Password Maximum Consecutive Repeating Characters | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_libpwquality hold |
| RHEL-09-611130 | Ensure PAM Enforces Password Requirements - Minimum Different Categories | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_libpwquality hold |
| RHEL-09-611135 | Set Password Hashing Algorithm in /etc/libuser.conf | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_libuser hold |
| RHEL-09-611140 | Set Password Hashing Algorithm in /etc/login.defs | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_shadow-utils hold |
| RHEL-09-611145 | Disallow Configuration to Bypass Password Requirements for Privilege Escalation | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_pam_and_system_with_kernel holds |
| RHEL-09-611155 | Ensure There Are No Accounts With Blank or Null Passwords | high | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-611160 | Configure opensc Smart Card Drivers | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-611165 | Enable Smartcards in SSSD | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_sssd holds |
| RHEL-09-611170 | Certificate status checking in SSSD | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_sssd holds |
| RHEL-09-611175 | Install the pcsc-lite package | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-611180 | Enable the pcscd Service | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-611185 | Install the opensc Package For Multifactor Authentication | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-611190 | Verify the SSH Private Key Files Have a Passcode | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_openssh-clients holds |
| RHEL-09-611195 | Require Authentication for Emergency Systemd Target | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-611200 | Require Authentication for Single User Mode | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-631010 | SSSD Has a Correct Trust Anchor | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_sssd holds |
| RHEL-09-631015 | Enable Certmap in SSSD | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_sssd holds |
| RHEL-09-631020 | Configure SSSD to Expire Offline Credentials | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_sssd holds |
| RHEL-09-651010 | Build and Test AIDE Database | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-651010 | Install AIDE | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-651015 | Configure Notification of Post-AIDE Scan Details | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-651020 | Configure AIDE to Use FIPS 140-2 for Validating Hashes | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-651025 | Configure AIDE to Verify the Audit Tools | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-651030 | Configure AIDE to Verify Access Control Lists (ACLs) | low | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-651035 | Configure AIDE to Verify Extended Attributes | low | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-652010 | Ensure rsyslog is Installed | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-652015 | Ensure rsyslog-gnutls is installed | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-652020 | Enable rsyslog Service | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-652025 | Ensure rsyslog Does Not Accept Remote Messages Unless Acting As Log Server | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-652030 | Ensure remote access methods are monitored in Rsyslog | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_rsyslog hold |
| RHEL-09-652040 | Ensure Rsyslog Authenticates Off-Loaded Audit Records | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_rsyslog hold |
| RHEL-09-652045 | Ensure Rsyslog Encrypts Off-Loaded Audit Records | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_rsyslog hold |
| RHEL-09-652050 | Ensure Rsyslog Encrypts Off-Loaded Audit Records | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_rsyslog hold |
| RHEL-09-652055 | Ensure Logs Sent To Remote Host | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-652060 | Ensure cron Is Logging To Rsyslog | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_rsyslog hold |
| RHEL-09-653010 | Ensure the audit Subsystem is Installed | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-653015 | Enable auditd Service | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-653020 | Configure auditd Disk Error Action on Disk Error | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-653025 | Configure auditd Disk Full Action when Disk Space Is Full | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-653030 | Configure a Sufficiently Large Partition for Audit Logs | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-653035 | Configure auditd space_left on Low Disk Space | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-653040 | Configure auditd space_left Action on Low Disk Space | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-653045 | Configure auditd admin_space_left on Low Disk Space | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-653050 | Configure auditd admin_space_left Action on Low Disk Space | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-653055 | Configure auditd max_log_file_action Upon Reaching Maximum Log Size | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-653060 | Set type of computer node name logging in audit logs | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-653065 | Appropriate Action Must be Setup When the Internal Audit Event Queue is Full | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-653070 | Configure auditd mail_acct Action on Low Disk Space | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-653075 | Include Local Events in Audit Logs | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-653080 | System Audit Directories Must Be Group Owned By Root | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-653085 | System Audit Directories Must Be Owned By Root | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-653090 | System Audit Logs Must Have Mode 0640 or Less Permissive | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-653095 | Set number of records to cause an explicit flush to audit logs | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-653100 | Resolve information before writing to audit logs | low | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-653105 | Write Audit Logs to the Disk | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-653110 | Audit Configuration Files Permissions are 600 or More Restrictive | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-653120 | Extend Audit Backlog Limit for the Audit Daemon | low | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and grub2 hold |
| RHEL-09-653125 | Configure System to Forward All Mail For The Root Account | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-653130 | Install audispd-plugins Package | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
| RHEL-09-654010 | Record Events When Privileged Executables Are Run | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654015 | Record Events that Modify the System's Discretionary Access Controls - chmod | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit and not_aarch64_arch hold |
| RHEL-09-654015 | Record Events that Modify the System's Discretionary Access Controls - fchmod | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654015 | Record Events that Modify the System's Discretionary Access Controls - fchmodat | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654020 | Record Events that Modify the System's Discretionary Access Controls - chown | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit and not_aarch64_arch hold |
| RHEL-09-654020 | Record Events that Modify the System's Discretionary Access Controls - fchown | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654020 | Record Events that Modify the System's Discretionary Access Controls - fchownat | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654020 | Record Events that Modify the System's Discretionary Access Controls - lchown | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit and not_aarch64_arch hold |
| RHEL-09-654025 | Record Events that Modify the System's Discretionary Access Controls - fremovexattr | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654025 | Record Events that Modify the System's Discretionary Access Controls - fsetxattr | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654025 | Record Events that Modify the System's Discretionary Access Controls - lremovexattr | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654025 | Record Events that Modify the System's Discretionary Access Controls - lsetxattr | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654025 | Record Events that Modify the System's Discretionary Access Controls - removexattr | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654025 | Record Events that Modify the System's Discretionary Access Controls - setxattr | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654030 | Ensure auditd Collects Information on the Use of Privileged Commands - umount | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654035 | Record Any Attempts to Run chacl | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654040 | Record Any Attempts to Run setfacl | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654045 | Record Any Attempts to Run chcon | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654050 | Record Any Attempts to Run semanage | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654055 | Record Any Attempts to Run setfiles | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654060 | Record Any Attempts to Run setsebool | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654065 | Ensure auditd Collects File Deletion Events by User - rename | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit and not_aarch64_arch hold |
| RHEL-09-654065 | Ensure auditd Collects File Deletion Events by User - renameat | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654065 | Ensure auditd Collects File Deletion Events by User - rmdir | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit and not_aarch64_arch hold |
| RHEL-09-654065 | Ensure auditd Collects File Deletion Events by User - unlink | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit and not_aarch64_arch hold |
| RHEL-09-654065 | Ensure auditd Collects File Deletion Events by User - unlinkat | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654070 | Record Unsuccessful Access Attempts to Files - creat | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit and not_aarch64_arch hold |
| RHEL-09-654070 | Record Unsuccessful Access Attempts to Files - ftruncate | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654070 | Record Unsuccessful Access Attempts to Files - open | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit and not_aarch64_arch hold |
| RHEL-09-654070 | Record Unsuccessful Access Attempts to Files - open_by_handle_at | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654070 | Record Unsuccessful Access Attempts to Files - openat | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654070 | Record Unsuccessful Access Attempts to Files - truncate | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654075 | Ensure auditd Collects Information on Kernel Module Unloading - delete_module | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654080 | Ensure auditd Collects Information on Kernel Module Loading and Unloading - finit_module | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654080 | Ensure auditd Collects Information on Kernel Module Loading - init_module | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654085 | Ensure auditd Collects Information on the Use of Privileged Commands - chage | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654090 | Ensure auditd Collects Information on the Use of Privileged Commands - chsh | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654095 | Ensure auditd Collects Information on the Use of Privileged Commands - crontab | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654097 | Audit Any Script or Executable Called by Cron as Root or by Any Privileged User | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654100 | Ensure auditd Collects Information on the Use of Privileged Commands - gpasswd | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654105 | Ensure auditd Collects Information on the Use of Privileged Commands - kmod | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654110 | Ensure auditd Collects Information on the Use of Privileged Commands - newgrp | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654115 | Ensure auditd Collects Information on the Use of Privileged Commands - pam_timestamp_check | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654120 | Ensure auditd Collects Information on the Use of Privileged Commands - passwd | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654125 | Ensure auditd Collects Information on the Use of Privileged Commands - postdrop | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654130 | Ensure auditd Collects Information on the Use of Privileged Commands - postqueue | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654135 | Record Any Attempts to Run ssh-agent | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654140 | Ensure auditd Collects Information on the Use of Privileged Commands - ssh-keysign | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654145 | Ensure auditd Collects Information on the Use of Privileged Commands - su | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654150 | Ensure auditd Collects Information on the Use of Privileged Commands - sudo | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654155 | Ensure auditd Collects Information on the Use of Privileged Commands - sudoedit | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654160 | Ensure auditd Collects Information on the Use of Privileged Commands - unix_chkpwd | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654165 | Ensure auditd Collects Information on the Use of Privileged Commands - unix_update | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654170 | Ensure auditd Collects Information on the Use of Privileged Commands - userhelper | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654175 | Ensure auditd Collects Information on the Use of Privileged Commands - usermod | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654180 | Ensure auditd Collects Information on the Use of Privileged Commands - mount | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654185 | Ensure auditd Collects Information on the Use of Privileged Commands - init | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654190 | Ensure auditd Collects Information on the Use of Privileged Commands - poweroff | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654195 | Ensure auditd Collects Information on the Use of Privileged Commands - reboot | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654200 | Ensure auditd Collects Information on the Use of Privileged Commands - shutdown | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654205 | Record Events that Modify the System's Discretionary Access Controls - umount | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit and not_aarch64_arch hold |
| RHEL-09-654210 | Record Events that Modify the System's Discretionary Access Controls - umount2 | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654215 | Ensure auditd Collects System Administrator Actions - /etc/sudoers | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654220 | Ensure auditd Collects System Administrator Actions - /etc/sudoers.d/ | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654225 | Record Events that Modify User/Group Information - /etc/group | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654230 | Record Events that Modify User/Group Information - /etc/gshadow | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654235 | Record Events that Modify User/Group Information - /etc/security/opasswd | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654240 | Record Events that Modify User/Group Information - /etc/passwd | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654245 | Record Events that Modify User/Group Information - /etc/shadow | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654250 | Record Attempts to Alter Logon and Logout Events - faillock | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654255 | Record Attempts to Alter Logon and Logout Events - lastlog | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654265 | Shutdown System When Auditing Failures Occur | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-654275 | Make the auditd Configuration Immutable | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_audit hold |
| RHEL-09-671010 | Set kernel parameter 'crypto.fips_enabled' to 1 | high | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_osbuild_and_system_with_kernel holds |
| RHEL-09-671015 | Verify All Account Password Hashes are Shadowed with SHA512 | medium | pass | met | OpenSCAP: pass |
| RHEL-09-671020 | Configure Libreswan to use System Crypto Policy | high | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_libreswan_and_system_with_kernel holds |
| RHEL-09-671025 | Set PAM Password Hashing Algorithm - password-auth | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel and package_pam hold |
| RHEL-09-672020 | Ensure System Cryptographic Policy Is Not Overridden | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where not_osbuild_and_system_with_kernel holds |
| RHEL-09-672050 | Configure BIND to use System Crypto Policy | high | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where package_bind holds |
|  | Enable authselect | medium | notapplicable | not applicable | OpenSCAP: notapplicable; the rule applies only where system_with_kernel holds |
