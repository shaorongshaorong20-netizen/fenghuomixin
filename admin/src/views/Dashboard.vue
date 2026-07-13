<template>
  <div class="grid">
    <el-card class="stat">
      <div class="label">总用户数</div>
      <div class="value">{{ totalUsers }}</div>
    </el-card>
    <el-card class="stat">
      <div class="label">今日消息数</div>
      <div class="value">{{ todayMessages }}</div>
      <div class="hint">占位数据</div>
    </el-card>
  </div>
</template>

<script setup>
import { onMounted, ref } from 'vue'
import { ElMessage } from 'element-plus'

import { fetchAccounts } from '../api'

const totalUsers = ref(0)
const todayMessages = ref(0)

onMounted(async () => {
  try {
    const data = await fetchAccounts()
    const list = data?.accounts || data?.data || []
    totalUsers.value = Array.isArray(list) ? list.length : 0
  } catch (e) {
    const msg = e?.response?.data?.message || e?.message || '加载失败'
    ElMessage.error(String(msg))
  }
})
</script>

<style scoped>
.grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 16px;
}

.stat {
  border-radius: 16px;
}

.label {
  color: #8b8b8b;
  font-size: 13px;
}

.value {
  margin-top: 8px;
  font-size: 32px;
  font-weight: 800;
  color: #e8e8e8;
}

.hint {
  margin-top: 6px;
  color: #555;
  font-size: 12px;
}
</style>

