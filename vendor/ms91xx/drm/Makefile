# SPDX-License-Identifier: GPL-2.0
#
# Makefile for MS91xx DRM core (in-tree Kbuild)
#

# 避免因为缺失原型声明等警告导致编译中止
ccflags-y += -Wno-error

obj-$(CONFIG_DRM_MS91XX) += usbdisp_drm.o

usbdisp_drm-y := \
	ms9132_hal.o \
	msdisp_common_util.o \
	msdisp_drm_connector.o \
	msdisp_drm_drv.o \
	msdisp_drm_encoder.o \
	msdisp_drm_fb.o \
	msdisp_drm_gem.o \
	msdisp_drm_interface.o \
	msdisp_drm_mode.o \
	msdisp_drm_modeset.o \
	msdisp_drm_sysfs.o \
	msdisp_plat_dev.o \
	msdisp_plat_drv.o \
	msdisp_usb_drv.o \
	hal_adaptor.o \
	usb_device.o \
	usb_hal_interface.o \
	usb_hal_sysfs.o \
	usb_hal_thread.o