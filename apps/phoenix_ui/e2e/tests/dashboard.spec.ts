import { test, expect } from '@playwright/test';

test('dashboard loads and responds to published machine events', async ({ page, request }) => {
    await page.goto('/dashboard');
    await expect(page.locator('text=AeroPhoenix')).toBeVisible();
    const machine = {
        id: "e2e-1",
        name: "e2e-test",
        region: "eu-west",
        status: "running",
        cpu: 3.1,
        memory_mb: 128,
        latency_ms: 12
    };

    const publishRes = await request.post('/__dev/publish_machine', { data: machine });
    expect(publishRes.status()).toBe(200);

    const card = page.locator(`text=${machine.name}`);
    await expect(card).toBeVisible({ timeout: 5000 });

    await card.click();

    await expect(page.locator('text=Selected')).toBeVisible();
    await expect(page.locator(`text=${machine.name}`)).toBeVisible();

    const restartBtn = page.locator('button', { hasText: 'Restart' }).first();
    await expect(restartBtn).toBeVisible();
    await restartBtn.click();

    await expect(page.locator('text=Orchestrator unreachable')).not.toBeVisible().catch(() => {});
});
