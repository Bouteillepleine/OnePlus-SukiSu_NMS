# Compatibility of OnePlus Kernels

## 1. OnePlus Devices

The build matrix supports OnePlus **A14, A15 and A16** targets. The current configuration inventory is:

| Target release | Configuration directory | Configuration count |
|---|---|---:|
| **A14** | `configs/a14/` | **13** |
| **A15** | `configs/a15/` | **74** |
| **A16** | `configs/a16/` | **71** |

These are target-release groups, for a total of **158 configurations**. A directory match alone is not enough: the device model, `os_version`, `android_version`, kernel version and source branch in the selected configuration must also match the phone.

### Standard feature defaults

All checked-in A14, A15 and A16 configurations use the following defaults:

| Component | Default |
|---|---:|
| **SukiSU Ultra** | **Built in** |
| **KPM** | **Enabled** |
| **SUSFS** | **Enabled** |
| **NoMount / NMS** | **Disabled** |
| **BBG** | **Disabled** |

The AnyKernel3 (AK3) package is non-interactive: it has **no volume-key feature selection** and does not enable optional features while flashing. It installs the feature set already compiled into the image, so the standard package keeps NoMount/NMS and BBG disabled.

> [!WARNING]
> Kernels are built from [official OnePlus sources](https://github.com/OnePlusOSS/) and are intended for the matching stock ROM. A custom kernel may also break hardware key-attestation and app compatibility.

- Match the exact device, A14/A15/A16 target and kernel base before flashing.
- Do not reuse a ZIP after a major Android/OxygenOS OTA such as A14 → A15 or A15 → A16. Wait for a matching build and verify compatibility through sources such as the [WildKernels Telegram group](https://t.me/WildKernels) or XDA.
- Keep a copy of the stock `boot.img` so the original kernel can be restored.

## 2. Non-OnePlus Devices
### List of verified devices
<table>
  <tr>
    <th> :warning: </th>
    <th> We expect all users who wants to test OnePlus Kernels on Non-OnePlus Phones to first disable dm-verity and verification using fastboot or other means.</th>
  </tr>
</table>

 - If your device is not in list, please select the device which is most similar and matches the kernel version (androidXX-YY.ZZ.AAA). AAA must be atleast same or greater. XX-YY.ZZ must match exactly. More Information on this can be read @<a href="https://kernelsu.org/guide/installation.html#kmi">KernelSU.org</a>.
 - Thanks to our community users at <a href="https://t.me/WildKernelsTG">WildKernels</a> for helping us compile the list.
 - We request more users come forward help us keep the list updated.
 - I'm sure more devices from other brands are also supported.
<table>
	<tr>
		<th align="center"> Device Name </th>
		<th align="center"> Working Kernel Device Name </th>
	    <th align="center"> Current Kernel Version </th>
	</tr>
	<tr>
		<td align="center"> Poco X7 Pro(used to work before)<br>Realme GT 7 Pro </td>
		<td align="center"> OnePlus 13<br>OnePlus Ace 5 Pro </td>
		<td align="center"> android15-6.6.89<br>android15-6.6.89 </td>
	</tr>
	<tr>
		<td align="center"> Realme GT Neo 5SE<br>Realme GT Neo 5 </td>
		<td align="center"> OnePlus 10T<br>OnePlus 10 Pro<br>OnePlus Ace 2<br>OnePlus 11r (Partially) </td>
		<td align="center"> android12-5.10.226<br>android12-5.10.226<br>android12-5.10.226<br>android12-5.10.209 </td>
	</tr>
	<tr>
		<td align="center"> Realme GT 5<br>Poco F6 Pro </td>
		<td align="center"> OnePlus 11<br>OnePlus 11 </td>
		<td align="center"> android13-5.15.167<br>android13-5.15.180 </td>
	</tr>
	<tr>
		<td align="center"> Realme GT Neo 6SE<br>Realme GT Neo 6T </td>
		<td align="center"> OnePlus Nord 4 </td>
		<td align="center"> android14-6.1.118 </td>
	</tr>
	<tr>
		<td align="center"> Realme GT 2 Pro </td>
		<td align="center"> OnePlus 10 Pro </td>
		<td align="center"> android12-5.10.226 </td>
	</tr>
	<tr>
		<td align="center"> Poco F8 Ultra </td>
		<td align="center"> OnePlus 15 </td>
		<td align="center"> android16-6.12.23 </td>
	</tr>
	<tr>
		<td align="center"> MI 12T Pro </td>
		<td align="center"> OnePlus 10T</td>
		<td align="center"> android12-5.10.226<br>android12-5.10.236</td>
	</tr>
</table>
