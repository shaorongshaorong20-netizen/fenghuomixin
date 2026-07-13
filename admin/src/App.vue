<template>
  <div class="app-root">
    <router-view v-if="isLogin" />
    <div v-else class="layout">
      <aside class="sidebar">
        <div class="brand">
          <div class="brand-mark"></div>
          <div class="brand-text">烽火密信</div>
        </div>
        <el-menu
          :default-active="activePath"
          class="menu"
          :router="true"
          background-color="#0F131E"
          text-color="#8B8B8B"
          active-text-color="#C62828"
        >
          <el-menu-item index="/dashboard">
            <el-icon><DataAnalysis /></el-icon>
            <span>仪表盘</span>
          </el-menu-item>
          <el-menu-item v-if="canAccounts" index="/accounts">
            <el-icon><User /></el-icon>
            <span>App账号管理</span>
          </el-menu-item>
          <el-menu-item v-if="canAudit" index="/audit">
            <el-icon><ChatLineSquare /></el-icon>
            <span>消息审计</span>
          </el-menu-item>
          <el-menu-item v-if="canLogs" index="/logs">
            <el-icon><Document /></el-icon>
            <span>系统日志</span>
          </el-menu-item>
          <el-menu-item v-if="isSuper" index="/admins">
            <el-icon><UserFilled /></el-icon>
            <span>管理员管理</span>
          </el-menu-item>
        </el-menu>
        <div class="sidebar-footer">
          <div class="user">{{ username || '管理员' }}</div>
          <el-button size="small" type="danger" plain @click="logout">退出</el-button>
        </div>
      </aside>
      <main class="main">
        <header class="topbar">
          <div class="title">{{ title }}</div>
          <div class="top-actions">
            <el-button size="small" @click="openChangePassword">修改密码</el-button>
          </div>
        </header>
        <div class="content">
          <router-view />
        </div>
      </main>
    </div>

    <el-dialog v-model="changeOpen" title="修改密码" width="420px">
      <el-form :model="changeForm" label-position="top">
        <el-form-item label="旧密码">
          <el-input v-model="changeForm.oldPassword" show-password type="password" />
        </el-form-item>
        <el-form-item label="新密码">
          <el-input v-model="changeForm.newPassword" show-password type="password" />
        </el-form-item>
        <el-form-item label="确认新密码">
          <el-input v-model="changeForm.confirmPassword" show-password type="password" />
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="changeOpen = false">取消</el-button>
        <el-button
          type="danger"
          :loading="changing"
          :disabled="!changeForm.oldPassword || !changeForm.newPassword || !changeForm.confirmPassword"
          @click="submitChangePassword"
        >
          确认
        </el-button>
      </template>
    </el-dialog>
  </div>
</template>

<script setup>
import { computed, onMounted, reactive, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { ElMessage } from 'element-plus'

import {
  changePassword,
  clearAdminSession,
  fetchAdminMe,
  getAdminPermissions,
  getAdminRole,
  getAdminUsername,
  setAdminPermissions,
  setAdminRole,
} from './api'

const route = useRoute()
const router = useRouter()

const isLogin = computed(() => route.path === '/login')
const activePath = computed(() => route.path)
const username = computed(() => getAdminUsername())
const role = computed(() => getAdminRole())
const perms = computed(() => getAdminPermissions())
const isSuper = computed(() => role.value === 'super' || username.value === 'admin')
const canAccounts = computed(() => isSuper.value || perms.value.manageAccounts === true)
const canAudit = computed(() => isSuper.value || perms.value.viewAudit === true)
const canLogs = computed(() => isSuper.value || perms.value.viewLogs === true)

const title = computed(() => {
  if (route.path === '/dashboard') return '仪表盘'
  if (route.path === '/accounts') return 'App账号管理'
  if (route.path === '/audit') return '消息审计'
  if (route.path === '/logs') return '系统日志'
  if (route.path === '/admins') return '管理员管理'
  return ''
})

onMounted(async () => {
  try {
    const me = await fetchAdminMe()
    const nextRole = me?.user?.role || me?.role || ''
    if (nextRole) setAdminRole(nextRole)
    if (me?.permissions) setAdminPermissions(me.permissions)
  } catch (_) {}
})

const changeOpen = ref(false)
const changing = ref(false)
const changeForm = reactive({
  oldPassword: '',
  newPassword: '',
  confirmPassword: '',
})

function openChangePassword() {
  changeForm.oldPassword = ''
  changeForm.newPassword = ''
  changeForm.confirmPassword = ''
  changeOpen.value = true
}

async function submitChangePassword() {
  if (changing.value) return
  if (changeForm.newPassword !== changeForm.confirmPassword) {
    ElMessage.error('两次新密码不一致')
    return
  }
  changing.value = true
  try {
    await changePassword({ oldPassword: changeForm.oldPassword, newPassword: changeForm.newPassword })
    ElMessage.success('密码已更新')
    changeOpen.value = false
  } catch (e) {
    const msg = e?.response?.data?.message || e?.message || '修改失败'
    ElMessage.error(String(msg))
  } finally {
    changing.value = false
  }
}

function logout() {
  clearAdminSession()
  router.replace('/login')
}
</script>

<style>
html,
body,
#app {
  height: 100%;
  margin: 0;
  background: #080c14;
}

.app-root {
  height: 100%;
  background: #080c14;
  color: #e8e8e8;
  font-family: system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue',
    Arial, 'Noto Sans', 'Apple Color Emoji', 'Segoe UI Emoji';
}

.layout {
  height: 100%;
  display: grid;
  grid-template-columns: 240px 1fr;
}

.sidebar {
  background: #0f131e;
  border-right: 1px solid #1a1f2e;
  display: flex;
  flex-direction: column;
}

.brand {
  height: 60px;
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 0 16px;
  border-bottom: 1px solid #1a1f2e;
}

.brand-mark {
  width: 10px;
  height: 10px;
  border-radius: 999px;
  background: #c62828;
  box-shadow: 0 0 0 4px rgba(198, 40, 40, 0.16);
}

.brand-text {
  font-weight: 700;
  color: #e8e8e8;
  letter-spacing: 2px;
}

.menu {
  border-right: none;
  flex: 1;
}

.sidebar-footer {
  padding: 12px 16px;
  border-top: 1px solid #1a1f2e;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
}

.user {
  color: #8b8b8b;
  font-size: 12px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.main {
  display: flex;
  flex-direction: column;
  min-width: 0;
}

.topbar {
  height: 60px;
  background: #0f131e;
  border-bottom: 1px solid #1a1f2e;
  display: flex;
  align-items: center;
  padding: 0 16px;
}

.title {
  font-size: 18px;
  font-weight: 700;
  color: #e8e8e8;
}

.top-actions {
  margin-left: auto;
  display: flex;
  gap: 10px;
}

.content {
  padding: 16px;
}

.el-card {
  background: #0f131e;
  border: 1px solid #1a1f2e;
  color: #e8e8e8;
}

.el-table {
  --el-table-bg-color: #0f131e;
  --el-table-tr-bg-color: #0f131e;
  --el-table-header-bg-color: #0f131e;
  --el-table-border-color: #1a1f2e;
  --el-table-text-color: #e8e8e8;
  --el-table-row-hover-bg-color: #141825;
}

.el-input__wrapper,
.el-textarea__inner {
  background: #141825;
  box-shadow: 0 0 0 1px #1a1f2e inset;
}
</style>
