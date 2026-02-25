#include <linux/module.h>
#include <linux/export-internal.h>
#include <linux/compiler.h>

MODULE_INFO(name, KBUILD_MODNAME);

__visible struct module __this_module
__section(".gnu.linkonce.this_module") = {
	.name = KBUILD_MODNAME,
	.init = init_module,
#ifdef CONFIG_MODULE_UNLOAD
	.exit = cleanup_module,
#endif
	.arch = MODULE_ARCH_INIT,
};


MODULE_INFO(depends, "");

MODULE_ALIAS("pci:v00001805d00000801sv*sd*bc*sc*i*");
MODULE_ALIAS("pci:v00001805d00000802sv*sd*bc*sc*i*");
MODULE_ALIAS("pci:v00001805d00000803sv*sd*bc*sc*i*");
MODULE_ALIAS("pci:v00001805d00000804sv*sd*bc*sc*i*");
MODULE_ALIAS("pci:v00001805d00000805sv*sd*bc*sc*i*");
MODULE_ALIAS("pci:v00001805d00000806sv*sd*bc*sc*i*");
MODULE_ALIAS("pci:v00001805d00000807sv*sd*bc*sc*i*");
MODULE_ALIAS("pci:v00001805d00000808sv*sd*bc*sc*i*");
MODULE_ALIAS("pci:v00001805d00000809sv*sd*bc*sc*i*");
MODULE_ALIAS("pci:v00001805d00000810sv*sd*bc*sc*i*");
MODULE_ALIAS("pci:v00001805d00000811sv*sd*bc*sc*i*");
MODULE_ALIAS("pci:v00001805d00000812sv*sd*bc*sc*i*");
MODULE_ALIAS("pci:v00001805d00000813sv*sd*bc*sc*i*");
MODULE_ALIAS("pci:v00001805d00000814sv*sd*bc*sc*i*");
MODULE_ALIAS("pci:v00001805d00000815sv*sd*bc*sc*i*");
MODULE_ALIAS("pci:v00001805d00000816sv*sd*bc*sc*i*");
MODULE_ALIAS("pci:v00001805d00000817sv*sd*bc*sc*i*");
MODULE_ALIAS("pci:v00001805d00000818sv*sd*bc*sc*i*");
MODULE_ALIAS("pci:v00001805d00000819sv*sd*bc*sc*i*");
MODULE_ALIAS("pci:v00001805d0000081Asv*sd*bc*sc*i*");
MODULE_ALIAS("pci:v00001805d0000081Bsv*sd*bc*sc*i*");
MODULE_ALIAS("pci:v00001805d0000081Csv*sd*bc*sc*i*");
MODULE_ALIAS("pci:v00001805d0000081Dsv*sd*bc*sc*i*");
